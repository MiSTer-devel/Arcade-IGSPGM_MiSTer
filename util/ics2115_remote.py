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
import json
import os
import struct
import subprocess
import tempfile
import time
from pathlib import Path
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
CMD_GET_IRQ_COUNTS_TIMED = 0x32
CMD_GET_IRQ_LOG = 0x33
CMD_READ_STATUS = 0x34
CMD_PEEK_Z80 = 0x35

IRQ_LOG_KIND_TIMER = 0
IRQ_LOG_KIND_IRQV = 1
IRQ_LOG_KIND_SPURIOUS = 2
IRQ_LOG_KIND_NAMES = {0: "timer", 1: "irqv", 2: "spurious"}

WIDTH_16 = 0
WIDTH_UPPER8 = 1
WIDTH_LOWER8 = 2

VOICE_FIELDS_STRUCT = struct.Struct(">BHHBHBBBBHHHBBBBB")
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
_add_reg(VOICE_REGISTERS, "vol_incr", 0x06, WIDTH_UPPER8, "VOL_INCR")
_add_reg(VOICE_REGISTERS, "vol_start", 0x07, WIDTH_UPPER8, "VOL_START")
_add_reg(VOICE_REGISTERS, "vol_end", 0x08, WIDTH_UPPER8, "VOL_END")
_add_reg(VOICE_REGISTERS, "vol_acc", 0x09, WIDTH_16, "VOL_ACC")
_add_reg(VOICE_REGISTERS, "osc_acc_hi", 0x0A, WIDTH_16, "OSC_ACC_H", "acc_hi")
_add_reg(VOICE_REGISTERS, "osc_acc_lo", 0x0B, WIDTH_16, "OSC_ACC_L", "acc_lo")
_add_reg(VOICE_REGISTERS, "pan", 0x0C, WIDTH_UPPER8, "PAN", "vol_pan")
_add_reg(VOICE_REGISTERS, "vol_ctrl", 0x0D, WIDTH_UPPER8, "VOL_CTRL")
_add_reg(VOICE_REGISTERS, "osc_ctl", 0x10, WIDTH_UPPER8, "OSC_CTL", "control")
_add_reg(VOICE_REGISTERS, "osc_saddr", 0x11, WIDTH_UPPER8, "OSC_SADDR", "saddr")
_add_reg(VOICE_REGISTERS, "vmode", 0x12, WIDTH_UPPER8, "VMode", "VMODE", "mode", "vol_mode")

_add_reg(GLOBAL_REGISTERS, "active_osc", 0x0E, WIDTH_UPPER8, "ACTIVE_OSC")
_add_reg(GLOBAL_REGISTERS, "irqv", 0x0F, WIDTH_UPPER8, "IRQV")
_add_reg(GLOBAL_REGISTERS, "timer0", 0x40, WIDTH_LOWER8, "TIMER0")
_add_reg(GLOBAL_REGISTERS, "timer1", 0x41, WIDTH_LOWER8, "TIMER1")
_add_reg(GLOBAL_REGISTERS, "timer_scale0", 0x42, WIDTH_LOWER8, "TIMER_SCALE0")
_add_reg(GLOBAL_REGISTERS, "timer_stat_scale1", 0x43, WIDTH_LOWER8, "TIMER_STAT", "TIMER_STAT_SCALE1")
_add_reg(GLOBAL_REGISTERS, "irq_enable", 0x4A, WIDTH_LOWER8, "IRQ_ENABLE")
_add_reg(GLOBAL_REGISTERS, "memory_config", 0x4C, WIDTH_LOWER8, "MEMORY_CONFIG")
_add_reg(GLOBAL_REGISTERS, "system_control", 0x4D, WIDTH_LOWER8, "SYSTEM_CONTROL", "SYS")
_add_reg(GLOBAL_REGISTERS, "osc_select", 0x4F, WIDTH_LOWER8, "OSC_SELECT")


class OscConf:
    IRQPending = 0x80
    Reverse = 0x40
    IRQEnable = 0x20
    Bidir = 0x10
    Loop = 0x08
    Unknown = 0x04
    WhiteNoise = 0x03
    Linear16 = 0x02
    ULaw8 = 0x01
    Linear8 = 0x00


class OscCtl:
    Hold = 0x02
    KeyOff = 0x0f
    KeyOn = 0x00


class VCtl:
    IRQPending = 0x80
    Reverse = 0x40
    IRQEnable = 0x20
    Bidir = 0x10
    Loop = 0x08
    Rollover = 0x04
    Stop = 0x02
    Done = 0x01


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
    vmode: int = 0

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
            self.vmode & 0xFF,
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
            vmode=0x00,
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


@dataclasses.dataclass
class IRQLogEntry:
    """One raw observation from the Z80 IRQ handler (see z80_ics_protocol.h).

    kind "timer":    a = 0x43 read value, b = status-port value
    kind "irqv":     a = IRQV read value, b = status-port value
    kind "spurious": a = status-port value, b = 0
    """

    seq: int
    kind: str
    a: int
    b: int


class SimServerError(ICSRemoteError):
    pass


class SimServerClient:
    """Small stdio JSON client for sim/sim --server."""

    def __init__(self, proc: subprocess.Popen[str], *, cwd: str | Path):
        self.proc = proc
        self.cwd = Path(cwd)
        self._next_id = 0

    @classmethod
    def start(cls, executable: str | Path = "./sim", *, cwd: str | Path = "sim") -> "SimServerClient":
        proc = subprocess.Popen(
            [str(executable), "--server"],
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        return cls(proc, cwd=cwd)

    def call(self, method: str, params: Optional[dict[str, Any]] = None) -> Any:
        if self.proc.stdin is None or self.proc.stdout is None:
            raise SimServerError("simulator server pipes are closed")
        self._next_id += 1
        req = {"id": self._next_id, "method": method, "params": params or {}}
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            stderr = ""
            if self.proc.stderr is not None:
                try:
                    stderr = self.proc.stderr.read()
                except Exception:
                    pass
            raise SimServerError(f"simulator server closed stdout; stderr={stderr!r}")
        rsp = json.loads(line)
        if not rsp.get("ok"):
            err = rsp.get("error", {})
            raise SimServerError(f"{method} failed: {err.get('code')}: {err.get('message')}")
        return rsp.get("result", {})

    def close(self) -> None:
        try:
            if self.proc.poll() is None:
                try:
                    self.call("sim.shutdown")
                except Exception:
                    pass
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        finally:
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                try:
                    if stream is not None:
                        stream.close()
                except Exception:
                    pass


class SimAudioCaptureReader:
    """Simulator audio capture adapter with the AudioStreamReader subset used here."""

    def __init__(self, sim: SimServerClient, *, sample_rate: int = 33074):
        self.sim = sim
        self.sample_rate_hz = sample_rate
        self.latest_samples: list[tuple[int, int]] = []

    def close(self) -> None:
        pass

    def _capture_for_cycles(self, cycles: int) -> list[tuple[int, int]]:
        try:
            from .capture_audio import AudioStreamReader
        except ImportError:
            from capture_audio import AudioStreamReader  # type: ignore

        fd, path = tempfile.mkstemp(prefix="pgm_sim_audio_", suffix=".bin")
        os.close(fd)
        try:
            self.sim.call("audio_capture.start", {"filename": path})
            self.sim.call("sim.run_cycles", {"count": cycles * 2})
            self.sim.call("audio_capture.stop")
            reader = AudioStreamReader.from_file(path)
            blocks = reader.read_audio_blocks(1_000_000, timeout=None)
            samples: list[tuple[int, int]] = []
            for block in blocks:
                samples.extend(block.samples)
            self.latest_samples.extend(samples)
            return samples
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    def capture_frames(self, count: int, *, timeout: Optional[float] = None) -> list[tuple[int, int]]:
        del timeout
        # The simulator is much slower than hardware; use deterministic simulated
        # time instead of wall-clock timeouts.  50 MHz / 33074 Hz ~= 1512 cycles.
        cycles = max(1, int((count * 50_000_000 + self.sample_rate_hz - 1) // self.sample_rate_hz) + 20_000)
        return self._capture_for_cycles(cycles)[:count]

    def capture_blocks(self, count: int, *, timeout: Optional[float] = None):
        del timeout
        try:
            from .capture_audio import AudioBlock
        except ImportError:
            from capture_audio import AudioBlock  # type: ignore
        samples = self._capture_for_cycles(max(1, count) * 4096 * 1600)
        if count <= 0:
            return []
        block_size = max(1, (len(samples) + count - 1) // count)
        return [AudioBlock({"type": 1, "frame_count": len(samples[i:i + block_size])}, samples[i:i + block_size])
                for i in range(0, len(samples), block_size)][:count]

    def get_latest_samples(self, count: int) -> list[tuple[int, int]]:
        return self.latest_samples[-count:]


class SimDebugLinkDevice:
    """Picorom-like transport backed by simulator debug_link.* methods."""

    def __init__(
        self,
        sim: SimServerClient,
        *,
        comms_addr: int = 0x1F800,
        timeout_cycles_per_byte: int = 2_000_000,
        read_timeout_cycles: int = 2_000_000,
    ):
        self.sim = sim
        self.comms_addr = comms_addr
        self.timeout_cycles_per_byte = timeout_cycles_per_byte
        self.read_timeout_cycles = read_timeout_cycles
        self._closed = False
        self.sim.call("debug_link.start", {"comms_addr": comms_addr})

    def write(self, data: bytes | bytearray) -> None:
        self.sim.call(
            "debug_link.write",
            {"data_hex": bytes(data).hex(), "timeout_cycles_per_byte": self.timeout_cycles_per_byte},
        )

    def read_exact(self, n: int) -> bytes:
        rsp = self.sim.call(
            "debug_link.read",
            {"max_bytes": n, "min_bytes": n, "timeout_cycles": self.read_timeout_cycles},
        )
        data = bytes.fromhex(rsp.get("data_hex", ""))
        return data if len(data) == n else b""

    def open_audio(self, *, latest_capacity: int = 65536) -> SimAudioCaptureReader:
        del latest_capacity
        return SimAudioCaptureReader(self.sim)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self.sim.call("debug_link.stop")
        finally:
            self.sim.close()


class SimICS2115Remote:
    """ICS2115Remote-compatible API using native simulator server methods.

    This intentionally avoids the TestROM/debug-link byte transport by default:
    the simulator is much slower than the real board, so native cycle-based
    commands are far faster and deterministic.  Audio capture still uses the
    simulator packet stream.
    """

    def __init__(self, sim: SimServerClient):
        self.sim = sim
        self.audio = None

    def close(self) -> None:
        if self.audio is not None:
            self.audio.close()
            self.audio = None
        self.sim.close()

    def __enter__(self) -> "SimICS2115Remote":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        del exc_type, exc, tb
        self.close()

    def _state(self) -> dict[str, Any]:
        return self.sim.call("ics2115.get_state")

    @staticmethod
    def _voice_from_state(v: dict[str, Any]) -> Voice:
        def split_addr(addr: int) -> tuple[int, int]:
            return (addr >> 13) & 0xFFFF, (addr >> 5) & 0xFF
        def split_acc(addr: int) -> tuple[int, int]:
            return (addr >> 13) & 0xFFFF, ((addr & 0x1FFF) << 3) & 0xFFFF
        start_hi, start_lo = split_addr(int(v.get("osc_start", 0)))
        end_hi, end_lo = split_addr(int(v.get("osc_end", 0)))
        acc_hi, acc_lo = split_acc(int(v.get("osc_acc", 0)))
        return Voice(
            osc_conf=int(v.get("osc_conf", 0)) & 0xFF,
            osc_fc=int(v.get("osc_fc", 0)) & 0xFFFF,
            osc_start_hi=start_hi,
            osc_start_lo=start_lo,
            osc_end_hi=end_hi,
            osc_end_lo=end_lo,
            vol_incr=int(v.get("vol_incr", 0)) & 0xFF,
            vol_start=(int(v.get("vol_start", 0)) >> 18) & 0xFF,
            vol_end=(int(v.get("vol_end", 0)) >> 18) & 0xFF,
            vol_acc=(int(v.get("vol_acc", 0)) >> 10) & 0xFFFF,
            osc_acc_hi=acc_hi,
            osc_acc_lo=acc_lo,
            pan=int(v.get("vol_pan", 0)) & 0xFF,
            vol_ctrl=int(v.get("vol_ctrl", 0)) & 0xFF,
            osc_ctl=int(v.get("osc_ctl", 0)) & 0xFF,
            osc_saddr=int(v.get("osc_saddr", 0)) & 0xFF,
            vmode=int(v.get("vol_mode", 0)) & 0xFF,
        )

    @staticmethod
    def _voice_to_state(index: int, value: Voice) -> dict[str, Any]:
        osc_conf = value.osc_conf & 0xFF
        state_on = value.osc_ctl == 0x00
        if state_on:
            osc_conf &= ~0x04
        elif value.osc_ctl == 0x0F:
            osc_conf |= 0x04
        return {
            "index": index & 0x1F,
            "osc_acc": value.acc_internal_addr & 0x1FFFFFFF,
            "osc_fc": value.osc_fc & 0xFFFE,
            "osc_start": value.start_internal_addr & 0x1FFFFFFF,
            "osc_end": value.end_internal_addr & 0x1FFFFFFF,
            "osc_saddr": value.osc_saddr & 0xFF,
            "osc_conf": osc_conf,
            "osc_ctl": value.osc_ctl & 0xFF,
            "vol_acc": (value.vol_acc & 0xFFFF) << 10,
            "vol_start": (value.vol_start & 0xFF) << 18,
            "vol_end": (value.vol_end & 0xFF) << 18,
            "vol_incr": value.vol_incr & 0xFF,
            "vol_pan": value.pan & 0xFF,
            "vol_ctrl": value.vol_ctrl & 0xFF,
            "vol_mode": value.vmode & 0xFF,
            "state_on": state_on,
        }

    def ping(self) -> PingInfo:
        return PingInfo(driver_magic=0x1C51, z80_status=0, z80_error=0, z80_seq=0)

    def init(self) -> PingInfo:
        # Simulator-native mode does not need the Z80 host-driver init path.
        return self.ping()

    def read_voice(self, voice: int) -> Voice:
        voices = self._state().get("voices", [])
        return self._voice_from_state(voices[voice & 0x1F])

    def write_voice(self, voice: int, value: Voice | dict[str, Any]) -> None:
        if isinstance(value, dict):
            value = Voice(**value)
        self.sim.call("ics2115.write_voice", self._voice_to_state(voice, value))

    def play_voice(self, voice: int, value: Optional[Voice] = None) -> None:
        if value is None:
            value = Voice.from_bios_trace()
        value.osc_ctl = 0x00
        self.write_voice(voice, value)

    def stop_voice(self, voice: int) -> None:
        v = self.read_voice(voice)
        v.osc_ctl = 0x0F
        self.write_voice(voice, v)

    def read_reg(self, voice: int, reg: str | int, width: Optional[int] = None) -> int:
        del width
        v = self.read_voice(voice)
        definition = ICS2115Remote._resolve_reg(reg, VOICE_REGISTERS)
        return int(getattr(v, definition.canonical))

    def write_reg(self, voice: int, reg: str | int, value: int, width: Optional[int] = None) -> None:
        del width
        v = self.read_voice(voice)
        definition = ICS2115Remote._resolve_reg(reg, VOICE_REGISTERS)
        setattr(v, definition.canonical, value)
        self.write_voice(voice, v)

    def read_global(self, reg: str | int, width: Optional[int] = None) -> int:
        del width
        definition = ICS2115Remote._resolve_reg(reg, GLOBAL_REGISTERS)
        state = self._state()
        mapping = {
            "active_osc": "active_osc",
            "osc_select": "osc_select",
            "irq_enable": "irq_enabled",
        }
        return int(state.get(mapping.get(definition.canonical, definition.canonical), 0))

    def write_global(self, reg: str | int, value: int, width: Optional[int] = None) -> None:
        del width
        definition = ICS2115Remote._resolve_reg(reg, GLOBAL_REGISTERS)
        mapping = {"irq_enable": "irq_enabled"}
        self.sim.call("ics2115.write_global", {"name": mapping.get(definition.canonical, definition.canonical), "value": value & 0xFFFF})

    def get_irq_counts(self) -> IRQCounts:
        return IRQCounts(0, 0, 0, 0, 0)

    def reset_irq_counts(self) -> IRQCounts:
        return IRQCounts(0, 0, 0, 0, 0)

    def open_audio(self, port: Optional[str] = None, *, latest_capacity: int = 65536):
        del port, latest_capacity
        self.audio = SimAudioCaptureReader(self.sim)
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

    @classmethod
    def open_sim(
        cls,
        *,
        executable: str | Path = "./sim",
        cwd: str | Path = "sim",
        game: Optional[str] = "pgm_test",
        mra: Optional[str | Path] = None,
        reset_cycles: Optional[int] = 100,
        comms_addr: int = 0x1F800,
        timeout: Optional[float] = None,
        timeout_cycles_per_byte: int = 2_000_000,
        read_timeout_cycles: int = 2_000_000,
        transport: str = "native",
    ) -> "ICS2115Remote | SimICS2115Remote":
        """Start sim/sim --server and expose the same remote API.

        By default this uses native simulator ICS2115 methods, not debug-link,
        because the simulator is much slower than hardware.  Pass
        transport="debug_link" to exercise the TestROM/debug-link path.
        """
        sim = SimServerClient.start(executable, cwd=cwd)
        try:
            sim.call("sim.initialize", {"headless": True})
            if mra is not None:
                sim.call("sim.load_mra", {"path": str(mra)})
            elif game is not None:
                sim.call("sim.load_game", {"name": game})
            if transport == "debug_link":
                dev = SimDebugLinkDevice(
                    sim,
                    comms_addr=comms_addr,
                    timeout_cycles_per_byte=timeout_cycles_per_byte,
                    read_timeout_cycles=read_timeout_cycles,
                )
                if reset_cycles is not None:
                    sim.call("sim.reset", {"cycles": reset_cycles})
                return cls(dev, timeout=timeout)
            if reset_cycles is not None:
                sim.call("sim.reset", {"cycles": reset_cycles})
            return SimICS2115Remote(sim)
        except Exception:
            sim.close()
            raise

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

    def get_irq_counts_timed(self, *, reset: bool = False) -> tuple[int, IRQCounts]:
        """Atomically sample the TestROM vblank frame counter and IRQ counts."""
        payload = self._request(CMD_GET_IRQ_COUNTS_TIMED, bytes([1 if reset else 0]))
        if len(payload) != 24:
            raise ICSRemoteProtocolError(f"bad timed irq payload length {len(payload)}")
        frame = struct.unpack(">I", payload[:4])[0]
        return frame, IRQCounts(*struct.unpack(">IIIII", payload[4:]))

    def get_irq_log(self, *, clear: bool = False) -> list[IRQLogEntry]:
        """Read the Z80 IRQ event ring (raw IRQV/0x43/status bytes, in order)."""
        payload = self._request(CMD_GET_IRQ_LOG, bytes([1 if clear else 0]))
        if not payload or len(payload) != 1 + payload[0] * 4:
            raise ICSRemoteProtocolError(f"bad irq log payload length {len(payload)}")
        entries = []
        for i in range(payload[0]):
            seq, kind, a, b = payload[1 + i * 4: 5 + i * 4]
            entries.append(IRQLogEntry(seq, IRQ_LOG_KIND_NAMES.get(kind, str(kind)), a, b))
        return entries

    def clear_irq_log(self) -> None:
        self.get_irq_log(clear=True)

    def peek_z80(self, addr: int, length: int) -> bytes:
        """Raw Z80-RAM read via the 68k bus; works with a wedged Z80."""
        if not 0 < length <= 64:
            raise ValueError("length must be 1..64")
        payload = self._request(CMD_PEEK_Z80, bytes([(addr >> 8) & 0xFF, addr & 0xFF, length]))
        return payload

    def read_status_port(self) -> int:
        """Raw ICS status port (Z80 port 0x8000) read by the Z80."""
        payload = self._request(CMD_READ_STATUS)
        if len(payload) != 2:
            raise ICSRemoteProtocolError(f"bad status payload length {len(payload)}")
        return struct.unpack(">H", payload)[0]

    def open_audio(self, port: Optional[str] = None, *, latest_capacity: int = 65536):
        open_sim_audio = getattr(self.picorom, "open_audio", None)
        if open_sim_audio is not None:
            self.audio = open_sim_audio(latest_capacity=latest_capacity)
            return self.audio

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
    "SimServerError",
    "SimServerClient",
    "SimICS2115Remote",
    "Voice",
    "PingInfo",
    "IRQCounts",
    "VOICE_REGISTERS",
    "GLOBAL_REGISTERS",
    "WIDTH_16",
    "WIDTH_UPPER8",
    "WIDTH_LOWER8",
]
