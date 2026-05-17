#!/usr/bin/env python3
"""Count distinct sound events in a captured WAV file.

This is intended for regression-checking repeated short PGM/ICS2115 sounds. It
builds a simple amplitude envelope from a PCM WAV, marks samples above a
threshold as active, merges nearby active regions, and reports the resulting
sound-event count.

Example:
    python3 utils/count_sound_events.py /tmp/z80_wave5_repeat.wav --expected 64
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import wave
from pathlib import Path
from typing import Iterable


def read_pcm16_wav(path: Path) -> tuple[int, int, list[int]]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.getnframes()
        raw = wav.readframes(frames)

    if sample_width != 2:
        raise SystemExit(f"Only 16-bit PCM WAV is supported; got sample width {sample_width}")
    if channels < 1:
        raise SystemExit("WAV has no channels")

    values = struct.unpack("<" + "h" * (len(raw) // 2), raw)
    # Per-frame absolute peak across channels. This catches either stereo side.
    peaks: list[int] = []
    for i in range(0, len(values), channels):
        peaks.append(max(abs(v) for v in values[i : i + channels]))
    return rate, channels, peaks


def rms(values: Iterable[int]) -> float:
    vals = list(values)
    if not vals:
        return 0.0
    return math.sqrt(sum(v * v for v in vals) / len(vals))


def auto_threshold(peaks: list[int], floor: int, peak_fraction: float) -> int:
    peak = max(peaks) if peaks else 0
    return max(floor, int(round(peak * peak_fraction)))


def make_event(index: int, peaks: list[int], start: int, end: int, rate: int) -> dict:
    segment = peaks[start:end]
    return {
        "index": index,
        "start_sample": start,
        "end_sample": end,
        "start_s": start / rate,
        "end_s": end / rate,
        "duration_s": (end - start) / rate,
        "max_peak": max(segment) if segment else 0,
        "rms_peak": rms(segment),
    }


def find_regions(
    peaks: list[int],
    *,
    rate: int,
    threshold: int,
    merge_gap_ms: float,
    min_duration_ms: float,
) -> list[dict]:
    merge_gap_samples = max(0, int(rate * merge_gap_ms / 1000.0))
    min_duration_samples = max(1, int(rate * min_duration_ms / 1000.0))

    raw_regions: list[tuple[int, int, int]] = []
    active = False
    start = 0
    last_active = 0
    max_peak = 0

    for idx, peak in enumerate(peaks):
        if peak >= threshold:
            if not active:
                active = True
                start = idx
                max_peak = peak
            else:
                max_peak = max(max_peak, peak)
            last_active = idx
        elif active and idx - last_active > merge_gap_samples:
            end = last_active + 1
            raw_regions.append((start, end, max_peak))
            active = False

    if active:
        raw_regions.append((start, last_active + 1, max_peak))

    regions: list[dict] = []
    for start, end, max_peak in raw_regions:
        if end - start < min_duration_samples:
            continue
        event = make_event(len(regions) + 1, peaks, start, end, rate)
        event["max_peak"] = max_peak
        regions.append(event)
    return regions


def find_dense_events(
    peaks: list[int],
    *,
    rate: int,
    threshold: int,
    envelope_ms: float,
    derivative_smooth_ms: float,
    min_period_ms: float,
    max_period_ms: float,
    min_duration_ms: float,
) -> list[dict]:
    """Detect repeated overlapping sounds by finding periodic envelope onsets.

    This is useful when repeated sounds overlap and threshold-region detection
    merges them into one continuous active block.  It estimates the repetition
    period with autocorrelation, then finds positive envelope-derivative peaks
    separated by roughly that period.
    """
    try:
        import numpy as np
    except ImportError as exc:
        raise SystemExit("Dense event detection requires numpy. Install with: python3 -m pip install --user numpy") from exc

    if not peaks or rate <= 0:
        return []

    peak_array = np.asarray(peaks, dtype=np.float32)
    active = np.flatnonzero(peak_array >= threshold)
    if active.size == 0:
        return []

    active_start = int(active[0])
    active_end = int(active[-1]) + 1
    if active_end <= active_start:
        return []

    envelope_window = max(1, int(rate * envelope_ms / 1000.0))
    kernel = np.ones(envelope_window, dtype=np.float32) / float(envelope_window)
    envelope = np.convolve(peak_array, kernel, mode="same")

    active_envelope = envelope[active_start:active_end].astype(np.float64)
    active_envelope -= float(active_envelope.mean())
    if active_envelope.size < 4:
        return []

    # FFT autocorrelation is fast enough for long captures and avoids O(n^2).
    n = 1 << (int(active_envelope.size) * 2 - 1).bit_length()
    spectrum = np.fft.rfft(active_envelope, n=n)
    corr = np.fft.irfft(spectrum * np.conj(spectrum), n=n)[: active_envelope.size]
    if corr[0] <= 0:
        return []

    min_lag = max(1, int(rate * min_period_ms / 1000.0))
    max_lag = min(int(rate * max_period_ms / 1000.0), int(corr.size) - 1)
    if max_lag <= min_lag:
        return []

    period = int(np.argmax(corr[min_lag : max_lag + 1]) + min_lag)

    derivative = np.diff(envelope, prepend=envelope[0])
    derivative = np.maximum(derivative, 0.0)
    derivative_window = max(1, int(rate * derivative_smooth_ms / 1000.0))
    if derivative_window > 1:
        derivative = np.convolve(derivative, np.ones(derivative_window, dtype=np.float32) / float(derivative_window), mode="same")

    active_derivative = derivative[active_start:active_end]
    if active_derivative.size == 0:
        return []

    peak_threshold = float(np.percentile(active_derivative, 95) * 0.4)
    if peak_threshold <= 0:
        return []

    min_distance = max(1, int(period * 0.75))
    search_radius = max(1, min_distance // 3)
    onset_samples: list[int] = []
    last_onset = -10**9

    for idx in range(active_start + 1, active_end - 1):
        if idx - last_onset < min_distance:
            continue
        if derivative[idx] >= peak_threshold and derivative[idx] >= derivative[idx - 1] and derivative[idx] > derivative[idx + 1]:
            lo = max(active_start, idx - search_radius)
            hi = min(active_end, idx + search_radius + 1)
            refined = int(lo + np.argmax(derivative[lo:hi]))
            if onset_samples and refined - onset_samples[-1] < min_distance:
                if derivative[refined] > derivative[onset_samples[-1]]:
                    onset_samples[-1] = refined
                    last_onset = refined
                continue
            onset_samples.append(refined)
            last_onset = refined

    min_duration_samples = max(1, int(rate * min_duration_ms / 1000.0))
    event_window = max(min_duration_samples, min(period, int(rate * 100.0 / 1000.0)))
    events: list[dict] = []
    for sample in onset_samples:
        start = int(sample)
        end = min(len(peaks), start + event_window)
        if end - start < min_duration_samples:
            continue
        event = make_event(len(events) + 1, peaks, start, end, rate)
        event["period_estimate_samples"] = period
        event["period_estimate_ms"] = period * 1000.0 / rate
        events.append(event)

    return events


def main() -> int:
    parser = argparse.ArgumentParser(description="Count distinct sound events in a 16-bit PCM WAV")
    parser.add_argument("wav", type=Path, help="Input WAV file")
    parser.add_argument("--expected", type=int, help="Expected event count; exit non-zero on mismatch")
    parser.add_argument("--threshold", type=int, help="Absolute PCM threshold. Default: auto")
    parser.add_argument("--threshold-floor", type=int, default=8, help="Minimum auto threshold; default 8")
    parser.add_argument(
        "--threshold-peak-fraction",
        type=float,
        default=0.05,
        help="Auto threshold as fraction of max peak; default 0.05",
    )
    parser.add_argument(
        "--merge-gap-ms",
        type=float,
        default=10.0,
        help="Merge active regions separated by less than this gap; default 10 ms",
    )
    parser.add_argument(
        "--min-duration-ms",
        type=float,
        default=10.0,
        help="Ignore active regions shorter than this; default 10 ms",
    )
    parser.add_argument(
        "--method",
        choices=("auto", "regions", "dense"),
        default="auto",
        help="Detection method. regions=threshold regions, dense=overlapping periodic events, auto=regions with dense fallback when expected count mismatches; default auto",
    )
    parser.add_argument("--dense-envelope-ms", type=float, default=2.0, help="Dense detector envelope smoothing window; default 2 ms")
    parser.add_argument("--dense-derivative-ms", type=float, default=1.0, help="Dense detector derivative smoothing window; default 1 ms")
    parser.add_argument("--dense-min-period-ms", type=float, default=30.0, help="Dense detector minimum repeat period; default 30 ms")
    parser.add_argument("--dense-max-period-ms", type=float, default=80.0, help="Dense detector maximum repeat period; default 80 ms")
    parser.add_argument("--json", action="store_true", help="Emit full JSON instead of text")
    parser.add_argument("--list", action="store_true", help="List each detected event in text mode")
    args = parser.parse_args()

    rate, channels, peaks = read_pcm16_wav(args.wav)
    threshold = args.threshold
    if threshold is None:
        threshold = auto_threshold(peaks, args.threshold_floor, args.threshold_peak_fraction)

    regions = find_regions(
        peaks,
        rate=rate,
        threshold=threshold,
        merge_gap_ms=args.merge_gap_ms,
        min_duration_ms=args.min_duration_ms,
    )
    method_used = "regions"

    dense_regions: list[dict] | None = None
    if args.method == "dense" or (
        args.method == "auto"
        and args.expected is not None
        and len(regions) != args.expected
        and len(regions) <= max(2, args.expected // 4)
    ):
        dense_regions = find_dense_events(
            peaks,
            rate=rate,
            threshold=threshold,
            envelope_ms=args.dense_envelope_ms,
            derivative_smooth_ms=args.dense_derivative_ms,
            min_period_ms=args.dense_min_period_ms,
            max_period_ms=args.dense_max_period_ms,
            min_duration_ms=args.min_duration_ms,
        )
        if args.method == "dense" or (args.expected is not None and len(dense_regions) == args.expected):
            regions = dense_regions
            method_used = "dense"

    peak = max(peaks) if peaks else 0
    nonzero = sum(1 for p in peaks if p != 0)
    result = {
        "input": str(args.wav),
        "sample_rate": rate,
        "channels": channels,
        "frames": len(peaks),
        "duration_s": len(peaks) / rate if rate else 0,
        "threshold": threshold,
        "method": method_used,
        "max_peak": peak,
        "nonzero_frames": nonzero,
        "merge_gap_ms": args.merge_gap_ms,
        "min_duration_ms": args.min_duration_ms,
        "event_count": len(regions),
        "expected": args.expected,
        "ok": args.expected is None or len(regions) == args.expected,
        "events": regions,
    }
    if dense_regions is not None and method_used != "dense":
        result["dense_event_count"] = len(dense_regions)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"input:      {args.wav}")
        print(f"rate:       {rate} Hz")
        print(f"duration:   {result['duration_s']:.3f} s")
        print(f"threshold:  {threshold}")
        print(f"method:     {method_used}")
        print(f"max_peak:   {peak}")
        print(f"events:     {len(regions)}")
        if args.expected is not None:
            print(f"expected:   {args.expected}")
            print(f"result:     {'PASS' if result['ok'] else 'FAIL'}")
        if args.list:
            for event in regions:
                print(
                    f"#{event['index']:03d} "
                    f"start={event['start_s']:.6f}s "
                    f"duration={event['duration_s']:.6f}s "
                    f"max={event['max_peak']} "
                    f"rms={event['rms_peak']:.2f}"
                )

    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
