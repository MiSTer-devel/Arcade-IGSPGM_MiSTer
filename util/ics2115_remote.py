#!/usr/bin/env python3
"""Python interface for the PGM TestROM ICS2115 remote-control page.

Hardware setup expected by open():

    import pypicorom
    p = pypicorom.open('pgm')
    p.start_comms(0x1f800)

The TestROM side is testroms/pages/ics_remote.c.  Values on the wire are
big-endian and responses are fixed-header frames, so read_exact() is used for
all response reads.
"""

from __future__ import annotations

import dataclasses
import enum
import struct
import time
from typing import Any, Optional

REQ_MAGIC = b"IC"
RSP_MAGIC = b"ic"
VERSION = 1
HEADER_SIZE = 6

STATUS_OK = 0x00
STATUS_BAD_MAGIC = 0x01
STATUS_BAD_VERSION = 0x02
STATUS_BAD_LENGTH = 0x03
STATUS_BAD_CMD = 0x04
STATUS_ICS_ERROR = 0x05

CMD_PING = 0x01
CMD_INIT = 0x02
CMD_READ_REG = 0x10
CMD_WRITE_REG = 0x11
CMD_READ_VOICE = 0x20
CMD_WRITE_VOICE = 0x21
CMD_GET_IRQ_COUNTS = 0x30
CMD_RESET_IRQ_COUNTS = 0x31

WIDTH_16 = 0
WIDTH_UPPER8 = 1
WIDTH_LOWER8 = 2

VOICE_FIELDS_STRUCT = struct.Struct(">BHHBHBBBBHHHBBBB")
VOICE_SIZE = 24
VOICE_RESERVED_SIZE = VOICE_SIZE - VOICE_FIELDS_STRUCT.size


class ICSRemoteError(RuntimeError):
    pass


class ICSRemoteProtocolError(ICSRemoteError):
    pass


class ICSRemoteCommandError(ICSRemoteError):
    def __init__(self, status: int, payload: bytes = b""):
        self.status = status
        self.payload = payload
        msg = f"ICS remote command failed: status=0x{status:02x}"
        if status == STATUS_ICS_ERROR and len(payload) >= 4:
            z80_status, z80_error = struct.unpack(">HH", payload[:4])
            self.z80_status = z80_status
            self.z80_error = z80_error
            msg += f" z80_status=0x{z80_status:04x} z80_error=0x{z80_error:04x}"
        super().__init__(msg)


@dataclasses.dataclass(frozen=True)
class RegisterDef:
    reg: int
    width: int
    canonical: str


VOICE_REGISTERS: dict[str, RegisterDef] = {}
GLOBAL_REGISTERS: dict[str, RegisterDef] = {}


def _add_reg(table: dict[str, RegisterDef], canonical: str, reg: int, width: int, *aliases: str) -> None:
    definition = RegisterDef(reg, width, canonical)
    for name in (canonical, canonical.upper(), *aliases):
        table[name] = definition
        table[name.lower()] = definition


_add_reg(VOICE_REGISTERS, "osc_conf", 0x00, WIDTH_UPPER8, "OSC_CONF", "conf")
_add_reg(VOICE_REGISTERS, "osc_fc", 0x01, WIDTH_16, "OSC_FC", "fc")
_add_reg(VOICE_REGISTERS, "osc_start_hi", 0x02, WIDTH_16, "OSC_START_H", "start_hi")
_add_reg(VOICE_REGISTERS, "osc_start_lo", 0x03, WIDTH_UPPER8, "OSC_START_L", "start_lo")
_add_reg(VOICE_REGISTERS, "osc_end_hi", 0x04, WIDTH_16, "OSC_END_H", "end_hi")
_add_reg(VOICE_REGISTERS, "osc_end_lo", 0x05, WIDTH_UPPER8, "OSC_END_L", "end_lo")
_add_reg(VOICE_REGISTERS, "vol_incr", 0x06, WIDTH_LOWER8, "VOL_INCR")
_add_reg(VOICE_REGISTERS, "vol_start", 0x07, WIDTH_LOWER8, "VOL_START")
_add_reg(VOICE_REGISTERS, "vol_end", 0x08, WIDTH_LOWER8, "VOL_END")
_add_reg(VOICE_REGISTERS, "vol_acc", 0x09, WIDTH_16, "VOL_ACC")
_add_reg(VOICE_REGISTERS, "osc_acc_hi", 0x0A, WIDTH_16, "OSC_ACC_H", "acc_hi")
_add_reg(VOICE_REGISTERS, "osc_acc_lo", 0x0B, WIDTH_16, "OSC_ACC_L", "acc_lo")
_add_reg(VOICE_REGISTERS, "pan", 0x0C, WIDTH_UPPER8, "PAN", "vol_pan")
_add_reg(VOICE_REGISTERS, "vol_ctrl", 0x0D, WIDTH_UPPER8, "VOL_CTRL")
_add_reg(VOICE_REGISTERS, "osc_ctl", 0x10, WIDTH_UPPER8, "OSC_CTL", "control")
_add_reg(VOICE_REGISTERS, "osc_saddr", 0x11, WIDTH_UPPER8, "OSC_SADDR", "saddr")

_add_reg(GLOBAL_REGISTERS, "active_osc", 0x0E, WIDTH_UPPER8, "ACTIVE_OSC")
_add_reg(GLOBAL_REGISTERS, "irqv", 0x0F, WIDTH_UPPER8, "IRQV")
_add_reg(GLOBAL_REGISTERS, "mode", 0x12, WIDTH_LOWER8, "MODE")
_add_reg(GLOBAL_REGISTERS, "timer0", 0x40, WIDTH_LOWER8, "TIMER0")
_add_reg(GLOBAL_REGISTERS, "timer1", 0x41, WIDTH_LOWER8, "TIMER1")
_add_reg(GLOBAL_REGISTERS, "timer_scale0", 0x42, WIDTH_LOWER8, "TIMER_SCALE0")
_add_reg(GLOBAL_REGISTERS, "timer_stat_scale1", 0x43, WIDTH_LOWER8, "TIMER_STAT", "TIMER_STAT_SCALE1")
_add_reg(GLOBAL_REGISTERS, "irq_enable", 0x4A, WIDTH_LOWER8, "IRQ_ENABLE")
_add_reg(GLOBAL_REGISTERS, "memory_config", 0x4C, WIDTH_LOWER8, "MEMORY_CONFIG")
_add_reg(GLOBAL_REGISTERS, "system_control", 0x4D, WIDTH_LOWER8, "SYSTEM_CONTROL", "SYS")
_add_reg(GLOBAL_REGISTERS, "osc_select", 0x4F, WIDTH_LOWER8, "OSC_SELECT")


@dataclasses.dataclass
class Voice:
    osc_conf: int = 0
    osc_fc: int = 0
    osc_start_hi: int = 0
    osc_start_lo: int = 0
    osc_end_hi: int = 0
    osc_end_lo: int = 0
    vol_incr: int = 0
    vol_start: int = 0
    vol_end: int = 0
    vol_acc: int = 0
    osc_acc_hi: int = 0
    osc_acc_lo: int = 0
    pan: int = 0
    vol_ctrl: int = 0
    osc_ctl: int = 0
    osc_saddr: int = 0

    @classmethod
    def unpack(cls, data: bytes) -> "Voice":
        if len(data) != VOICE_SIZE:
            raise ValueError(f"voice payload must be {VOICE_SIZE} bytes, got {len(data)}")
        return cls(*VOICE_FIELDS_STRUCT.unpack(data[:VOICE_FIELDS_STRUCT.size]))

    def pack(self) -> bytes:
        fields = VOICE_FIELDS_STRUCT.pack(
            self.osc_conf & 0xFF,
            self.osc_fc & 0xFFFF,
            self.osc_start_hi & 0xFFFF,
            self.osc_start_lo & 0xFF,
            self.osc_end_hi & 0xFFFF,
            self.osc_end_lo & 0xFF,
            self.vol_incr & 0xFF,
            self.vol_start & 0xFF,
            self.vol_end & 0xFF,
            self.vol_acc & 0xFFFF,
            self.osc_acc_hi & 0xFFFF,
            self.osc_acc_lo & 0xFFFF,
            self.pan & 0xFF,
            self.vol_ctrl & 0xFF,
            self.osc_ctl & 0xFF,
            self.osc_saddr & 0xFF,
        )
        return fields + (b"\x00" * VOICE_RESERVED_SIZE)

    @classmethod
    def from_bios_trace(cls) -> "Voice":
        """Known-good voice-0 values traced from z80_sound_test START."""
        return cls(
            osc_conf=0x20,
            osc_fc=0x0155,
            osc_start_hi=0xB63A,
            osc_start_lo=0x60,
            osc_end_hi=0xB81E,
            osc_end_lo=0xB0,
            vol_incr=0x00,
            vol_start=0x00,
            vol_end=0x00,
            vol_acc=0xDFF0,
            osc_acc_hi=0xB63A,
            osc_acc_lo=0x6000,
            pan=0x7F,
            vol_ctrl=0x03,
            osc_ctl=0x00,
            osc_saddr=0x40,
        )

    @property
    def loop_enabled(self) -> bool:
        return bool(self.osc_conf & 0x08)

    @property
    def osc_irq_enabled(self) -> bool:
        return bool(self.osc_conf & 0x20)

    @property
    def volume_irq_enabled(self) -> bool:
        return bool(self.vol_ctrl & 0x20)

    @staticmethod
    def _wave_addr(hi: int, lo: int) -> int:
        return ((hi & 0xFFFF) << 4) | ((lo & 0xFF) >> 4)

    @staticmethod
    def _internal_addr(hi: int, lo: int) -> int:
        return ((hi & 0xFFFF) << 13) | ((lo & 0xFF) << 5)

    @property
    def start_wave_addr(self) -> int:
        return self._wave_addr(self.osc_start_hi, self.osc_start_lo)

    @property
    def end_wave_addr(self) -> int:
        return self._wave_addr(self.osc_end_hi, self.osc_end_lo)

    @property
    def acc_wave_addr(self) -> int:
        return ((self.osc_saddr & 0xFF) << 20) | ((self.osc_acc_hi & 0xFFFF) << 4) | ((self.osc_acc_lo & 0xFFFF) >> 12)

    @property
    def start_internal_addr(self) -> int:
        return self._internal_addr(self.osc_start_hi, self.osc_start_lo)

    @property
    def end_internal_addr(self) -> int:
        return self._internal_addr(self.osc_end_hi, self.osc_end_lo)

    @property
    def acc_internal_addr(self) -> int:
        return ((self.osc_saddr & 0xFF) << 24) | ((self.osc_acc_hi & 0xFFFF) << 13) | ((self.osc_acc_lo & 0xFFFF) >> 3)

    def set_start_wave_addr(self, addr: int) -> None:
        self.osc_start_hi = (addr >> 4) & 0xFFFF
        self.osc_start_lo = (addr & 0xF) << 4

    def set_end_wave_addr(self, addr: int) -> None:
        self.osc_end_hi = (addr >> 4) & 0xFFFF
        self.osc_end_lo = (addr & 0xF) << 4

    def set_acc_wave_addr(self, addr: int) -> None:
        self.osc_saddr = 0x40  # (addr >> 20) & 0xFF
        self.osc_acc_hi = (addr >> 4) & 0xFFFF
        self.osc_acc_lo = (addr & 0xF) << 12

    def to_dict(self, *, derived: bool = True) -> dict[str, int | bool]:
        out = dataclasses.asdict(self)
        if derived:
            out.update(
                loop_enabled=self.loop_enabled,
                osc_irq_enabled=self.osc_irq_enabled,
                volume_irq_enabled=self.volume_irq_enabled,
                start_wave_addr=self.start_wave_addr,
                end_wave_addr=self.end_wave_addr,
                acc_wave_addr=self.acc_wave_addr,
                start_internal_addr=self.start_internal_addr,
                end_internal_addr=self.end_internal_addr,
                acc_internal_addr=self.acc_internal_addr,
            )
        return out


@dataclasses.dataclass
class PingInfo:
    driver_magic: int
    z80_status: int
    z80_error: int
    z80_seq: int


@dataclasses.dataclass
class IRQCounts:
    timer0: int
    timer1: int
    osc: int
    vol: int
    spurious: int


class ICS2115Remote:
    def __init__(self, picorom, *, timeout: Optional[float] = None):
        self.picorom = picorom
        self.timeout = timeout
        self.seq = 0
        self.audio = None

    @classmethod
    def open(cls, target: str = "pgm", comms_addr: int = 0x1F800, *, reset: Optional[str] = None, timeout: Optional[float] = None) -> "ICS2115Remote":
        import pypicorom

        p = pypicorom.open(target)
        p.end_comms()
        if reset:
            p.set_parameter("reset", reset)
            time.sleep(0.1)
            p.set_parameter("reset", "z")
        p.start_comms(comms_addr)
        return cls(p, timeout=timeout)

    def close(self) -> None:
        if self.audio is not None:
            self.audio.close()
            self.audio = None
        close = getattr(self.picorom, "close", None)
        if close is not None:
            close()

    def __enter__(self) -> "ICS2115Remote":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        del exc_type, exc, tb
        self.close()

    def _read_exact(self, n: int) -> bytes:
        data = self.picorom.read_exact(n)
        if data is None or len(data) != n:
            raise ICSRemoteProtocolError(f"short read: wanted {n}, got {0 if data is None else len(data)}")
        return bytes(data)

    def _request(self, cmd: int, payload: bytes = b"") -> bytes:
        if len(payload) > 255:
            raise ValueError("payload too large for ICS remote protocol")
        self.seq = (self.seq + 1) & 0xFF
        frame = REQ_MAGIC + bytes([VERSION, self.seq, cmd & 0xFF, len(payload)]) + payload
        self.picorom.write(frame)

        hdr = self._read_exact(HEADER_SIZE)
        if hdr[:2] != RSP_MAGIC:
            raise ICSRemoteProtocolError(f"bad response magic: {hdr[:2]!r}")
        version, seq, status, length = hdr[2], hdr[3], hdr[4], hdr[5]
        if version != VERSION:
            raise ICSRemoteProtocolError(f"bad response version: {version}")
        if seq != self.seq:
            raise ICSRemoteProtocolError(f"bad response seq: got {seq}, expected {self.seq}")
        rsp_payload = self._read_exact(length) if length else b""
        if status != STATUS_OK:
            raise ICSRemoteCommandError(status, rsp_payload)
        return rsp_payload

    @staticmethod
    def _resolve_reg(reg: str | int, table: dict[str, RegisterDef]) -> RegisterDef:
        if isinstance(reg, str):
            try:
                return table[reg]
            except KeyError as exc:
                raise KeyError(f"unknown ICS2115 register name {reg!r}") from exc
        return RegisterDef(reg & 0xFF, WIDTH_16, f"0x{reg & 0xFF:02x}")

    def ping(self) -> PingInfo:
        payload = self._request(CMD_PING)
        if len(payload) != 7:
            raise ICSRemoteProtocolError(f"bad ping payload length {len(payload)}")
        driver_magic, z80_status, z80_error, z80_seq = struct.unpack(">HHHB", payload)
        return PingInfo(driver_magic, z80_status, z80_error, z80_seq)

    def init(self) -> PingInfo:
        payload = self._request(CMD_INIT)
        if len(payload) != 7:
            raise ICSRemoteProtocolError(f"bad init payload length {len(payload)}")
        driver_magic, z80_status, z80_error, z80_seq = struct.unpack(">HHHB", payload)
        return PingInfo(driver_magic, z80_status, z80_error, z80_seq)

    def read_reg(self, voice: int, reg: str | int, width: Optional[int] = None) -> int:
        definition = self._resolve_reg(reg, VOICE_REGISTERS)
        payload = self._request(CMD_READ_REG, bytes([voice & 0x1F, definition.reg, definition.width if width is None else width]))
        if len(payload) != 2:
            raise ICSRemoteProtocolError(f"bad read_reg payload length {len(payload)}")
        return struct.unpack(">H", payload)[0]

    def write_reg(self, voice: int, reg: str | int, value: int, width: Optional[int] = None) -> None:
        definition = self._resolve_reg(reg, VOICE_REGISTERS)
        payload = bytes([voice & 0x1F, definition.reg, definition.width if width is None else width]) + struct.pack(">H", value & 0xFFFF)
        self._request(CMD_WRITE_REG, payload)

    def read_global(self, reg: str | int, width: Optional[int] = None) -> int:
        definition = self._resolve_reg(reg, GLOBAL_REGISTERS)
        payload = self._request(CMD_READ_REG, bytes([0, definition.reg, definition.width if width is None else width]))
        if len(payload) != 2:
            raise ICSRemoteProtocolError(f"bad read_global payload length {len(payload)}")
        return struct.unpack(">H", payload)[0]

    def write_global(self, reg: str | int, value: int, width: Optional[int] = None) -> None:
        definition = self._resolve_reg(reg, GLOBAL_REGISTERS)
        payload = bytes([0, definition.reg, definition.width if width is None else width]) + struct.pack(">H", value & 0xFFFF)
        self._request(CMD_WRITE_REG, payload)

    def read_voice(self, voice: int) -> Voice:
        payload = self._request(CMD_READ_VOICE, bytes([voice & 0x1F]))
        return Voice.unpack(payload)

    def write_voice(self, voice: int, value: Voice | dict[str, Any]) -> None:
        if isinstance(value, dict):
            value = Voice(**value)
        self._request(CMD_WRITE_VOICE, bytes([voice & 0x1F]) + value.pack())

    def play_voice(self, voice: int, value: Optional[Voice] = None) -> None:
        if value is None:
            value = Voice.from_bios_trace()
        value.osc_ctl = 0x00
        self.write_voice(voice, value)

    def stop_voice(self, voice: int) -> None:
        self.write_reg(voice, "osc_ctl", 0x0F)

    def get_irq_counts(self) -> IRQCounts:
        payload = self._request(CMD_GET_IRQ_COUNTS)
        if len(payload) != 20:
            raise ICSRemoteProtocolError(f"bad irq payload length {len(payload)}")
        return IRQCounts(*struct.unpack(">IIIII", payload))

    def reset_irq_counts(self) -> IRQCounts:
        payload = self._request(CMD_RESET_IRQ_COUNTS)
        if len(payload) != 20:
            raise ICSRemoteProtocolError(f"bad irq payload length {len(payload)}")
        return IRQCounts(*struct.unpack(">IIIII", payload))

    def open_audio(self, port: Optional[str] = None, *, latest_capacity: int = 65536):
        try:
            from .capture_audio import AudioStreamReader
        except ImportError:
            from capture_audio import AudioStreamReader  # type: ignore

        self.audio = AudioStreamReader.open(port, latest_capacity=latest_capacity)
        return self.audio

    def latest_audio_samples(self, count: int, *, blocks: Optional[int] = None, timeout: Optional[float] = 1.0) -> list[tuple[int, int]]:
        if self.audio is None:
            raise RuntimeError("audio reader is not open; call open_audio() first")
        if blocks is not None:
            captured = []
            for block in self.audio.capture_blocks(blocks, timeout=timeout):
                captured.extend(block.samples)
            return captured[-count:]
        return self.audio.capture_frames(count, timeout=timeout)

    def capture_audio_frames(self, count: int, *, timeout: Optional[float] = 1.0) -> list[tuple[int, int]]:
        if self.audio is None:
            raise RuntimeError("audio reader is not open; call open_audio() first")
        return self.audio.capture_frames(count, timeout=timeout)


__all__ = [
    "ICS2115Remote",
    "ICSRemoteError",
    "ICSRemoteProtocolError",
    "ICSRemoteCommandError",
    "Voice",
    "PingInfo",
    "IRQCounts",
    "VOICE_REGISTERS",
    "GLOBAL_REGISTERS",
    "WIDTH_16",
    "WIDTH_UPPER8",
    "WIDTH_LOWER8",
]
