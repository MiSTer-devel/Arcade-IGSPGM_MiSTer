#!/usr/bin/env python3
"""Compare two WAV audio captures containing one sound effect plus silence.

The tool ignores sample-rate metadata.  WAV files are treated as ordered PCM
sample lists.  It trims leading/trailing exact zero samples, aligns the two
captures by their first non-zero sample, compares the active regions, and emits
human and JSON summaries intended to categorize differences rather than require
bit-exact equality.
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import wave
import zlib
from pathlib import Path
from typing import Any

try:
    import numpy as np
except ImportError as exc:  # pragma: no cover
    raise SystemExit("numpy is required; run with `uv run` or install numpy") from exc


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CAPTURE_DIR = ROOT / "audio_captures"


class CompareError(RuntimeError):
    pass


def resolve_capture_path(path: str) -> Path:
    p = Path(path)
    if p.exists():
        return p
    candidate = DEFAULT_CAPTURE_DIR / path
    if candidate.exists():
        return candidate
    if p.suffix == "":
        candidate = DEFAULT_CAPTURE_DIR / f"{path}.wav"
        if candidate.exists():
            return candidate
    raise CompareError(f"file not found: {path}")


def read_wav(path: Path) -> tuple[np.ndarray, dict[str, Any]]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sampwidth = wav.getsampwidth()
        frames = wav.getnframes()
        rate = wav.getframerate()
        raw = wav.readframes(frames)

    if channels <= 0:
        raise CompareError(f"{path}: invalid channel count {channels}")

    if sampwidth == 1:
        # Unsigned 8-bit PCM -> signed centered int16-ish values.
        data = np.frombuffer(raw, dtype=np.uint8).astype(np.int16) - 128
    elif sampwidth == 2:
        data = np.frombuffer(raw, dtype="<i2").astype(np.int32)
    elif sampwidth == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        values = (b[:, 0].astype(np.int32) |
                  (b[:, 1].astype(np.int32) << 8) |
                  (b[:, 2].astype(np.int32) << 16))
        data = ((values << 8) >> 8).astype(np.int32)
    elif sampwidth == 4:
        data = np.frombuffer(raw, dtype="<i4").astype(np.int64)
    else:
        raise CompareError(f"{path}: unsupported sample width {sampwidth} bytes")

    if len(data) % channels:
        raise CompareError(f"{path}: sample count is not divisible by channel count")
    samples = data.reshape(-1, channels)
    info = {
        "path": str(path),
        "channels": channels,
        "sample_width_bytes": sampwidth,
        "sample_rate_ignored": rate,
        "frames": int(samples.shape[0]),
    }
    return samples, info


def active_bounds(samples: np.ndarray, threshold: int = 0) -> tuple[int | None, int | None]:
    active = np.any(np.abs(samples) > threshold, axis=1)
    idx = np.flatnonzero(active)
    if idx.size == 0:
        return None, None
    return int(idx[0]), int(idx[-1])


def ensure_channels(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    if a.shape[1] == b.shape[1]:
        return a, b
    if a.shape[1] == 1 and b.shape[1] == 2:
        return np.repeat(a, 2, axis=1), b
    if a.shape[1] == 2 and b.shape[1] == 1:
        return a, np.repeat(b, 2, axis=1)
    raise CompareError(f"channel mismatch: {a.shape[1]} vs {b.shape[1]}")


def rms(x: np.ndarray) -> float:
    if x.size == 0:
        return 0.0
    xf = x.astype(np.float64)
    return float(np.sqrt(np.mean(xf * xf)))


def corrcoef(a: np.ndarray, b: np.ndarray) -> float | None:
    if a.size < 2 or b.size < 2:
        return None
    af = a.astype(np.float64).ravel()
    bf = b.astype(np.float64).ravel()
    if np.std(af) == 0 or np.std(bf) == 0:
        return None
    return float(np.corrcoef(af, bf)[0, 1])


def gain_estimate(ref: np.ndarray, test: np.ndarray) -> float | None:
    rf = ref.astype(np.float64).ravel()
    tf = test.astype(np.float64).ravel()
    denom = float(np.dot(rf, rf))
    if denom == 0:
        return None
    return float(np.dot(rf, tf) / denom)


def channel_metrics(ref: np.ndarray, test: np.ndarray) -> dict[str, Any]:
    diff = test.astype(np.float64) - ref.astype(np.float64)
    gain = gain_estimate(ref, test)
    residual = test.astype(np.float64) - (ref.astype(np.float64) * gain if gain is not None else ref.astype(np.float64))
    ref_rms = rms(ref)
    test_rms = rms(test)
    diff_rms = rms(diff)
    residual_rms = rms(residual)
    return {
        "ref_peak_abs": int(np.max(np.abs(ref))) if ref.size else 0,
        "test_peak_abs": int(np.max(np.abs(test))) if test.size else 0,
        "ref_rms": ref_rms,
        "test_rms": test_rms,
        "diff_max_abs": int(np.max(np.abs(diff))) if diff.size else 0,
        "diff_mean_abs": float(np.mean(np.abs(diff))) if diff.size else 0.0,
        "diff_rms": diff_rms,
        "diff_rms_norm": None if ref_rms == 0 else diff_rms / ref_rms,
        "gain": gain,
        "gain_db": None if not gain or gain <= 0 else 20.0 * math.log10(gain),
        "dc_offset": float(np.mean(diff)) if diff.size else 0.0,
        "correlation": corrcoef(ref, test),
        "residual_rms_after_gain": residual_rms,
        "residual_rms_norm_after_gain": None if ref_rms == 0 else residual_rms / ref_rms,
        "snr_db": None if diff_rms == 0 or ref_rms == 0 else 20.0 * math.log10(ref_rms / diff_rms),
        "snr_db_after_gain": None if residual_rms == 0 or ref_rms == 0 else 20.0 * math.log10(ref_rms / residual_rms),
    }


def estimate_lag(ref: np.ndarray, test: np.ndarray, max_lag: int) -> dict[str, Any]:
    if max_lag <= 0 or ref.size == 0 or test.size == 0:
        return {"best_lag": 0, "best_correlation": None}
    ref_mix = ref.astype(np.float64).mean(axis=1)
    test_mix = test.astype(np.float64).mean(axis=1)
    best_lag = 0
    best_corr = -2.0
    for lag in range(-max_lag, max_lag + 1):
        if lag < 0:
            a = ref_mix[-lag:]
            b = test_mix[:len(a)]
        elif lag > 0:
            a = ref_mix[:-lag]
            b = test_mix[lag:]
        else:
            a = ref_mix
            b = test_mix
        n = min(len(a), len(b))
        if n < 4:
            continue
        c = corrcoef(a[:n], b[:n])
        if c is not None and c > best_corr:
            best_corr = c
            best_lag = lag
    return {"best_lag": best_lag, "best_correlation": None if best_corr == -2.0 else best_corr}


def categorize(result: dict[str, Any]) -> list[str]:
    cats: list[str] = []
    if result["ref"]["active_start"] is None:
        cats.append("reference_silent")
    if result["test"]["active_start"] is None:
        cats.append("test_silent")
    if cats:
        return cats

    length_delta = result["alignment"]["active_length_delta"]
    ref_len = max(result["ref"]["active_length"], 1)
    if abs(length_delta) > max(8, ref_len * 0.02):
        cats.append("length_mismatch")

    lag = result["lag_diagnostic"]["best_lag"]
    if lag:
        cats.append("possible_residual_timing_shift")

    gain_ok = True
    gains = [ch["gain"] for ch in result["channels"] if ch["gain"] is not None]
    if gains:
        avg_gain = sum(gains) / len(gains)
        if avg_gain < -0.5:
            cats.append("polarity_inverted")
            gain_ok = False
        elif abs(avg_gain - 1.0) > 0.10:
            cats.append("amplitude_gain_mismatch")
            gain_ok = False
        elif abs(avg_gain - 1.0) > 0.03:
            cats.append("minor_amplitude_gain_difference")
        if len(gains) == 2 and abs(gains[0] - gains[1]) > 0.08:
            cats.append("channel_balance_mismatch")
            gain_ok = False

    residuals = [ch["residual_rms_norm_after_gain"] for ch in result["channels"] if ch["residual_rms_norm_after_gain"] is not None]
    if residuals and gain_ok:
        r = max(residuals)
        if r > 0.25:
            cats.append("large_waveform_difference")
        elif r > 0.08:
            cats.append("moderate_waveform_difference")
        elif r > 0.02:
            cats.append("small_waveform_difference")
        else:
            cats.append("close_match")

    dc_offsets = [abs(ch["dc_offset"]) for ch in result["channels"]]
    if dc_offsets and max(dc_offsets) > 64:
        cats.append("dc_offset_difference")

    return cats or ["uncategorized"]


def compare(ref_path: Path, test_path: Path, *, threshold: int = 0, max_lag: int = 128) -> dict[str, Any]:
    ref, ref_info = read_wav(ref_path)
    test, test_info = read_wav(test_path)
    ref, test = ensure_channels(ref, test)

    rs, re = active_bounds(ref, threshold)
    ts, te = active_bounds(test, threshold)
    ref_info.update({"active_start": rs, "active_end": re})
    test_info.update({"active_start": ts, "active_end": te})

    if rs is None or ts is None:
        result = {
            "ref": ref_info,
            "test": test_info,
            "alignment": {},
            "channels": [],
            "lag_diagnostic": {"best_lag": 0, "best_correlation": None},
        }
        result["categories"] = categorize(result)
        return result

    ref_active = ref[rs:re + 1]
    test_active = test[ts:te + 1]
    n = min(len(ref_active), len(test_active))
    ref_cmp = ref_active[:n]
    test_cmp = test_active[:n]

    ref_info["active_length"] = int(len(ref_active))
    test_info["active_length"] = int(len(test_active))

    channels = [channel_metrics(ref_cmp[:, c], test_cmp[:, c]) for c in range(ref_cmp.shape[1])]
    lag = estimate_lag(ref_cmp, test_cmp, max_lag)
    result = {
        "ref": ref_info,
        "test": test_info,
        "alignment": {
            "method": "first_nonzero",
            "ref_aligned_start": rs,
            "test_aligned_start": ts,
            "compared_frames": int(n),
            "ref_extra_tail_frames": int(max(0, len(ref_active) - n)),
            "test_extra_tail_frames": int(max(0, len(test_active) - n)),
            "active_length_delta": int(len(test_active) - len(ref_active)),
            "zero_threshold": threshold,
        },
        "channels": channels,
        "overall": channel_metrics(ref_cmp, test_cmp),
        "lag_diagnostic": lag,
    }
    result["categories"] = categorize(result)
    return result


def fmt_float(v: Any, digits: int = 4) -> str:
    if v is None:
        return "n/a"
    return f"{float(v):.{digits}f}"


def print_text(result: dict[str, Any]) -> None:
    print("Audio capture comparison")
    print(f"  ref : {result['ref']['path']}")
    print(f"  test: {result['test']['path']}")
    print(f"  categories: {', '.join(result['categories'])}")
    if not result.get("alignment"):
        print("  one or both files are silent")
        return
    a = result["alignment"]
    print("Alignment")
    print(f"  method: {a['method']}")
    print(f"  starts: ref={a['ref_aligned_start']} test={a['test_aligned_start']}")
    print(f"  active lengths: ref={result['ref']['active_length']} test={result['test']['active_length']} delta={a['active_length_delta']}")
    print(f"  compared frames: {a['compared_frames']}")
    lag = result["lag_diagnostic"]
    print(f"  lag diagnostic: best_lag={lag['best_lag']} corr={fmt_float(lag['best_correlation'])}")
    print("Overall")
    o = result["overall"]
    print(f"  gain={fmt_float(o['gain'])} ({fmt_float(o['gain_db'], 2)} dB) corr={fmt_float(o['correlation'])}")
    print(f"  diff_rms={fmt_float(o['diff_rms'], 2)} norm={fmt_float(o['diff_rms_norm'])} snr={fmt_float(o['snr_db'], 2)} dB")
    print(f"  residual_after_gain_rms={fmt_float(o['residual_rms_after_gain'], 2)} norm={fmt_float(o['residual_rms_norm_after_gain'])} snr={fmt_float(o['snr_db_after_gain'], 2)} dB")
    for i, ch in enumerate(result["channels"]):
        print(f"Channel {i}")
        print(f"  gain={fmt_float(ch['gain'])} ({fmt_float(ch['gain_db'], 2)} dB) corr={fmt_float(ch['correlation'])} dc={fmt_float(ch['dc_offset'], 2)}")
        print(f"  diff_max={ch['diff_max_abs']} diff_rms={fmt_float(ch['diff_rms'], 2)} residual_norm={fmt_float(ch['residual_rms_norm_after_gain'])}")


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


def write_simple_png(path: Path, result: dict[str, Any], width: int = 1200, height: int = 500) -> None:
    # Dependency-free RGB plot: ref=test overlay and diff magnitude.
    ref, _ = read_wav(Path(result["ref"]["path"]))
    test, _ = read_wav(Path(result["test"]["path"]))
    ref, test = ensure_channels(ref, test)
    a = result["alignment"]
    rs = a["ref_aligned_start"]
    ts = a["test_aligned_start"]
    n = a["compared_frames"]
    ref = ref[rs:rs+n].astype(np.float64).mean(axis=1)
    test = test[ts:ts+n].astype(np.float64).mean(axis=1)
    if n == 0:
        raise CompareError("nothing to plot")
    scale = max(float(np.max(np.abs(ref))), float(np.max(np.abs(test))), 1.0)
    img = np.full((height, width, 3), 255, dtype=np.uint8)
    mid = height // 3
    diff_mid = 2 * height // 3
    xs = np.linspace(0, n - 1, width).astype(np.int64)
    ref_y = np.clip(mid - (ref[xs] / scale * (height * 0.28)).astype(int), 0, height - 1)
    test_y = np.clip(mid - (test[xs] / scale * (height * 0.28)).astype(int), 0, height - 1)
    diff = np.abs(test - ref)
    diff_scale = max(float(np.max(diff)), 1.0)
    diff_y = np.clip(diff_mid - (diff[xs] / diff_scale * (height * 0.25)).astype(int), 0, height - 1)
    for x, y in enumerate(ref_y):
        img[y, x] = (40, 90, 220)
    for x, y in enumerate(test_y):
        img[y, x] = (220, 80, 40)
    for x, y in enumerate(diff_y):
        img[y, x] = (20, 160, 60)
    img[mid, :, :] = (200, 200, 200)
    img[diff_mid, :, :] = (200, 200, 200)
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(height))
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += png_chunk(b"IDAT", zlib.compress(raw, 6))
    png += png_chunk(b"IEND", b"")
    path.write_bytes(png)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare two WAV captures by trimming silence and aligning first non-zero samples")
    parser.add_argument("ref", help="Reference WAV path or name under audio_captures/")
    parser.add_argument("test", help="Test WAV path or name under audio_captures/")
    parser.add_argument("--json", dest="json_path", help="Write JSON report to this path")
    parser.add_argument("--plot", help="Optional PNG overlay/difference plot path")
    parser.add_argument("--threshold", type=int, default=0, help="Absolute sample threshold considered non-silent (default: 0)")
    parser.add_argument("--max-lag", type=int, default=128, help="Diagnostic cross-correlation lag search window in frames (default: 128)")
    args = parser.parse_args(argv)

    try:
        result = compare(resolve_capture_path(args.ref), resolve_capture_path(args.test), threshold=args.threshold, max_lag=args.max_lag)
        print_text(result)
        if args.json_path:
            Path(args.json_path).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        if args.plot:
            write_simple_png(Path(args.plot), result)
    except CompareError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
