#!/usr/bin/env python3
"""Reusable reader for the PGM serial audio packet stream.

This module contains the importable audio-reading pieces of capture_stream.py.
It intentionally does not print.  Callers can read a few packet blocks and ask
for the latest decoded stereo samples.
"""

from __future__ import annotations

import collections
import dataclasses
import struct
import time
from pathlib import Path
from typing import Deque, Iterable, Optional

try:  # package import when used as util.capture_audio
    from .capture_stream import (
        FileSource,
        SerialSource,
        choose_port,
        decode_header,
        decode_status,
        decode_control,
        read_exact,
        sync_to_magic,
        HDR_SIZE,
        MAGIC,
        READ_SIZE,
        STATUS_SIZE,
        CONTROL_SIZE,
        TYPE_AUDIO,
        TYPE_STATUS,
        TYPE_CONTROL,
    )
except ImportError:  # direct import from util/ on PYTHONPATH
    from capture_stream import (  # type: ignore
        FileSource,
        SerialSource,
        choose_port,
        decode_header,
        decode_status,
        decode_control,
        read_exact,
        sync_to_magic,
        HDR_SIZE,
        MAGIC,
        READ_SIZE,
        STATUS_SIZE,
        CONTROL_SIZE,
        TYPE_AUDIO,
        TYPE_STATUS,
        TYPE_CONTROL,
    )


@dataclasses.dataclass
class AudioBlock:
    header: dict
    samples: list[tuple[int, int]]


CONTROL_MAGIC = 0x434D4750
CONTROL_VERSION = 1
CONTROL_CMD_FLUSH = 1
CONTROL_CMD_CONTINUOUS = 2
CONTROL_CMD_IDLE = 3
CONTROL_CMD_ARM_FRAMES = 4
CONTROL_CMD_ARM_BLOCKS = 5
CONTROL_CMD_STATUS = 6
CONTROL_STATUS_OK = 0
CONTROL_MODE_CONTINUOUS = 0
CONTROL_MODE_IDLE = 1
CONTROL_MODE_ARM_FRAMES = 2
CONTROL_MODE_ARM_BLOCKS = 3
CONTROL_COMMAND_FMT = "<IHHII"


class AudioControlError(RuntimeError):
    pass


class AudioStreamReader:
    """Decode native PGM audio packets from a serial port or packet file."""

    def __init__(self, source, *, latest_capacity: int = 65536):
        self.source = source
        self.buf = bytearray()
        self.latest_samples: Deque[tuple[int, int]] = collections.deque(maxlen=latest_capacity)
        self.rate_counter: collections.Counter[int] = collections.Counter()
        self.audio_packets = 0
        self.status_packets = 0
        self.latest_status: Optional[dict] = None
        self.latest_control: Optional[dict] = None
        self._control_seq = 0

    @classmethod
    def open(cls, port: Optional[str] = None, *, latest_capacity: int = 65536) -> "AudioStreamReader":
        selected = choose_port(port)
        if not selected:
            raise RuntimeError("No serial audio port found")
        return cls(SerialSource(selected), latest_capacity=latest_capacity)

    @classmethod
    def from_file(cls, path: str | Path, *, latest_capacity: int = 65536) -> "AudioStreamReader":
        return cls(FileSource(path), latest_capacity=latest_capacity)

    def close(self) -> None:
        self.source.close()

    def __enter__(self) -> "AudioStreamReader":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        del exc_type, exc, tb
        self.close()

    def _deadline(self, timeout: Optional[float]) -> Optional[float]:
        return None if timeout is None else time.time() + timeout

    def read_packet(self, *, timeout: Optional[float] = None) -> Optional[tuple[dict, bytes]]:
        """Read the next packet.  Returns None on timeout/end-of-file."""
        deadline = self._deadline(timeout)
        if not sync_to_magic(self.source, self.buf, deadline):
            return None
        hdr_data = read_exact(self.source, self.buf, HDR_SIZE, deadline)
        if hdr_data is None:
            return None
        hdr = decode_header(hdr_data)
        if hdr.get("magic") != MAGIC:
            return None
        payload = read_exact(self.source, self.buf, hdr["payload_bytes"], deadline)
        if payload is None:
            return None
        return hdr, payload

    @staticmethod
    def decode_samples(payload: bytes) -> list[tuple[int, int]]:
        return [
            struct.unpack_from("<hh", payload, offset)
            for offset in range(0, len(payload) - 3, 4)
        ]

    def read_audio_block(self, *, timeout: Optional[float] = None) -> Optional[AudioBlock]:
        """Read packets until one audio block is decoded."""
        deadline = self._deadline(timeout)
        while deadline is None or time.time() < deadline:
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            packet = self.read_packet(timeout=remaining)
            if packet is None:
                return None
            hdr, payload = packet
            if hdr["type"] == TYPE_AUDIO:
                samples = self.decode_samples(payload)
                self.latest_samples.extend(samples)
                self.audio_packets += 1
                if hdr.get("raw_lrclk_hz"):
                    self.rate_counter[hdr["raw_lrclk_hz"]] += hdr.get("frame_count", len(samples))
                return AudioBlock(hdr, samples)
            if hdr["type"] == TYPE_STATUS:
                self.status_packets += 1
                if len(payload) == STATUS_SIZE:
                    self.latest_status = decode_status(payload)
            elif hdr["type"] == TYPE_CONTROL:
                if len(payload) == CONTROL_SIZE:
                    self.latest_control = decode_control(payload)
        return None

    def read_audio_blocks(self, count: int, *, timeout: Optional[float] = None) -> list[AudioBlock]:
        """Read up to count audio blocks."""
        blocks: list[AudioBlock] = []
        deadline = self._deadline(timeout)
        while len(blocks) < count:
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            block = self.read_audio_block(timeout=remaining)
            if block is None:
                break
            blocks.append(block)
        return blocks

    def get_latest_samples(self, count: int) -> list[tuple[int, int]]:
        """Return the newest count stereo samples already decoded."""
        if count <= 0:
            return []
        data = list(self.latest_samples)
        return data[-count:]

    def read_latest_samples(
        self,
        count: int,
        *,
        blocks: Optional[int] = None,
        timeout: Optional[float] = 1.0,
    ) -> list[tuple[int, int]]:
        """Read audio and return the newest count samples.

        If blocks is None, packets are read until at least count samples have
        been buffered or timeout expires.  If blocks is an integer, exactly that
        many audio blocks are attempted first.
        """
        if blocks is not None:
            self.read_audio_blocks(blocks, timeout=timeout)
            return self.get_latest_samples(count)

        deadline = self._deadline(timeout)
        while len(self.latest_samples) < count:
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            if deadline is not None and remaining <= 0:
                break
            if self.read_audio_block(timeout=remaining) is None:
                break
        return self.get_latest_samples(count)

    def _send_control(self, cmd: int, arg: int = 0, *, timeout: Optional[float] = 1.0) -> dict:
        write = getattr(self.source, "write", None)
        if write is None:
            raise AudioControlError("audio source does not support control writes")
        self._control_seq = (self._control_seq + 1) & 0xFFFFFFFF
        frame = struct.pack(CONTROL_COMMAND_FMT, CONTROL_MAGIC, CONTROL_VERSION, cmd, self._control_seq, arg)
        write(frame)

        deadline = self._deadline(timeout)
        while deadline is None or time.time() < deadline:
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            packet = self.read_packet(timeout=remaining)
            if packet is None:
                break
            hdr, payload = packet
            if hdr["type"] == TYPE_AUDIO:
                samples = self.decode_samples(payload)
                self.latest_samples.extend(samples)
                self.audio_packets += 1
                if hdr.get("raw_lrclk_hz"):
                    self.rate_counter[hdr["raw_lrclk_hz"]] += hdr.get("frame_count", len(samples))
            elif hdr["type"] == TYPE_STATUS:
                self.status_packets += 1
                if len(payload) == STATUS_SIZE:
                    self.latest_status = decode_status(payload)
            elif hdr["type"] == TYPE_CONTROL and len(payload) == CONTROL_SIZE:
                control = decode_control(payload)
                self.latest_control = control
                if control["seq"] == self._control_seq:
                    if control["status"] != CONTROL_STATUS_OK:
                        raise AudioControlError(f"control command failed: {control}")
                    return control
        raise AudioControlError("timed out waiting for audio control ACK")

    def flush(self, *, timeout: Optional[float] = 1.0) -> dict:
        self.latest_samples.clear()
        return self._send_control(CONTROL_CMD_FLUSH, 0, timeout=timeout)

    def set_continuous(self, *, timeout: Optional[float] = 1.0) -> dict:
        return self._send_control(CONTROL_CMD_CONTINUOUS, 0, timeout=timeout)

    def set_idle(self, *, timeout: Optional[float] = 1.0) -> dict:
        return self._send_control(CONTROL_CMD_IDLE, 0, timeout=timeout)

    def arm_frames(self, count: int, *, timeout: Optional[float] = 1.0) -> dict:
        self.latest_samples.clear()
        return self._send_control(CONTROL_CMD_ARM_FRAMES, count, timeout=timeout)

    def arm_blocks(self, count: int, *, timeout: Optional[float] = 1.0) -> dict:
        self.latest_samples.clear()
        return self._send_control(CONTROL_CMD_ARM_BLOCKS, count, timeout=timeout)

    def get_control_status(self, *, timeout: Optional[float] = 1.0) -> dict:
        return self._send_control(CONTROL_CMD_STATUS, 0, timeout=timeout)

    def capture_frames(self, count: int, *, timeout: Optional[float] = 1.0) -> list[tuple[int, int]]:
        """Ask firmware to flush and send the next count stereo frames.

        Firmware discards a couple of internal DMA blocks after the arm command,
        then returns only newly captured audio. This avoids stale USB/CDC data
        without closing/reopening the serial port.
        """
        self.arm_frames(count, timeout=timeout)
        out: list[tuple[int, int]] = []
        deadline = self._deadline(timeout)
        while len(out) < count:
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            block = self.read_audio_block(timeout=remaining)
            if block is None:
                break
            out.extend(block.samples)
        return out[:count]

    def capture_blocks(self, count: int, *, timeout: Optional[float] = 1.0) -> list[AudioBlock]:
        self.arm_blocks(count, timeout=timeout)
        return self.read_audio_blocks(count, timeout=timeout)

    def sample_rate(self, fallback: int = 33074) -> int:
        if not self.rate_counter:
            return fallback
        return self.rate_counter.most_common(1)[0][0]
