#!/usr/bin/env python3
"""Dump section sizes from an IGSPGM .pgmstate save-state file.

Save-state format notes, as implemented by rtl/memory_stream.sv:
- byte 0x00: 64-bit little-endian stream header
  - bits [31:0]  : save/write generation counter
  - bits [63:32] : stream length in 32-bit words
- byte 0x08: repeated section records
  - 64-bit little-endian section header
    - bits [31:0]  : item count
    - bits [33:32] : item width code: 0=8-bit, 1=16-bit, 2=32-bit, 3=64-bit
    - bits [60:56] : save-state section index / SSIDX
  - payload follows, occupying align8(count * item_width) bytes, OPTIONALLY
    followed by a 1-word spacer/handshake slot. The spacer is present for some
    sections and absent for others (it depends on the saving adaptor), so it
    must NOT be assumed universally - the parser probes for it by checking
    whether the next record is a valid (higher-indexed) header or terminator.
- terminator: a 64-bit word with high byte 0xff, normally 0xffffffffffffffff

Update prompt for future agents:
When the save-state structure changes, update this script before relying on it:
1. Check rtl/system_consts.sv for SSIDX_* additions, removals, or renumbering.
   This script auto-parses that file when run inside the repo, but keep the
   FALLBACK_SECTION_NAMES map current for standalone use.
2. Check rtl/savestates.sv and rtl/memory_stream.sv. If the stream header,
   chunk header, width encoding, section index bits, payload spacer/padding,
   or terminator format changes, update parse_pgmstate() and this docstring.
3. Check each ssbus.setup() implementation. If a section's count/width changes,
   no parser change should be needed, but regenerate a save and confirm the
   reported logical sizes match the RTL intent.
4. Rebuild the simulator, create a fresh save state, then run:
      util/dump_pgmstate.py sim/states/<game>/<file>.pgmstate
   Compare old/new output and mention any intentional layout changes in your
   commit/session notes.
"""

from __future__ import annotations

import argparse
import json
import re
import struct
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]

FALLBACK_SECTION_NAMES = {
    0: "GLOBAL",
    1: "WORK_RAM",
    2: "VIDEO_RAM",
    3: "PAL_RAM",
    4: "IGS023",
    5: "Z80_RAM",
    6: "Z80",
    7: "IGS026_X",
    8: "ICS2115",
    9: "ASIC3",
}

UPDATE_PROMPT = __doc__.split("Update prompt for future agents:", 1)[1].strip()


@dataclass
class Section:
    index: int
    name: str
    offset: int
    data_offset: int
    count: int
    width_code: int
    item_bytes: int
    logical_bytes: int
    stored_bytes: int
    next_offset: int
    raw_header: int


@dataclass
class DumpResult:
    path: str
    file_size: int
    save_counter: int
    stream_length_bytes: int
    stream_end_offset: int
    parsed_end_offset: int
    sentinel_offset: int | None
    trailing_bytes: int
    sections: list[Section]
    warnings: list[str]


def load_section_names(repo_root: Path) -> dict[int, str]:
    names = dict(FALLBACK_SECTION_NAMES)
    consts = repo_root / "rtl" / "system_consts.sv"
    if not consts.exists():
        return names

    pattern = re.compile(r"parameter\s+int\s+SSIDX_([A-Za-z0-9_]+)\s*=\s*(\d+)\s*;")
    for match in pattern.finditer(consts.read_text()):
        label = match.group(1)
        index = int(match.group(2), 10)
        names[index] = label
    return names


def align8(value: int) -> int:
    return (value + 7) & ~7


def read_u64_le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def parse_pgmstate(path: Path, section_names: dict[int, str]) -> DumpResult:
    data = path.read_bytes()
    warnings: list[str] = []
    sections: list[Section] = []

    if len(data) < 8:
        raise ValueError(f"{path}: file is too small to contain a save-state header")

    stream_header = read_u64_le(data, 0)
    save_counter = stream_header & 0xFFFFFFFF
    stream_length_bytes = ((stream_header >> 32) & 0xFFFFFFFF) << 2
    stream_end_offset = 8 + stream_length_bytes

    if stream_length_bytes == 0:
        warnings.append("stream length is zero; parsing until file end")
        stream_end_offset = len(data)
    elif stream_end_offset > len(data):
        warnings.append(
            f"stream header length extends past file end: end=0x{stream_end_offset:x}, file=0x{len(data):x}"
        )
        stream_end_offset = len(data)

    offset = 8
    sentinel_offset: int | None = None

    while offset + 8 <= stream_end_offset:
        raw = read_u64_le(data, offset)
        high_byte = (raw >> 56) & 0xFF

        if high_byte == 0xFF:
            sentinel_offset = offset
            offset += 8
            break

        count = raw & 0xFFFFFFFF
        width_code = (raw >> 32) & 0x3
        item_bytes = 1 << width_code
        logical_bytes = count * item_bytes
        index = high_byte & 0x1F
        data_offset = offset + 8

        # Some sections are followed by a 1-word "spacer"/handshake slot and some
        # are not (it depends on the saving adaptor), so the spacer cannot be
        # assumed universally: an earlier `align8((count + 1) * item_bytes)`
        # over-counts no-spacer sections whose payload is already 8-aligned
        # (e.g. IGS022_RAM_LO's 8192 bytes), landing 8 bytes into the next
        # section and desyncing. Instead, take the un-spaced size and probe for
        # the spacer: the real next record is a terminator, the stream end, or a
        # higher-indexed section header (sections are saved in ascending index).
        def next_is_record(o: int) -> bool:
            if o == stream_end_offset:
                return True
            if o + 8 > stream_end_offset:
                return False
            nxt = read_u64_le(data, o)
            if (nxt >> 56) & 0xFF == 0xFF:
                return True
            return ((nxt >> 56) & 0x1F) > index

        unspaced = align8(logical_bytes)
        if next_is_record(data_offset + unspaced):
            stored_bytes = unspaced
        elif next_is_record(data_offset + unspaced + 8):
            stored_bytes = unspaced + 8
        else:
            warnings.append(
                f"section {index} ({section_names.get(index, '?')}) data ends in garbage "
                f"at 0x{data_offset + unspaced:x}; stream is corrupt or layout changed"
            )
            stored_bytes = unspaced
        next_offset = data_offset + stored_bytes

        if high_byte & 0xE0:
            warnings.append(
                f"section at 0x{offset:x} has non-zero reserved index bits in high byte 0x{high_byte:02x}"
            )

        if next_offset > stream_end_offset:
            warnings.append(
                f"section {index} payload extends past stream end: next=0x{next_offset:x}, end=0x{stream_end_offset:x}"
            )
            stored_bytes = max(0, stream_end_offset - data_offset)
            next_offset = stream_end_offset

        sections.append(
            Section(
                index=index,
                name=section_names.get(index, f"UNKNOWN_{index}"),
                offset=offset,
                data_offset=data_offset,
                count=count,
                width_code=width_code,
                item_bytes=item_bytes,
                logical_bytes=logical_bytes,
                stored_bytes=stored_bytes,
                next_offset=next_offset,
                raw_header=raw,
            )
        )
        offset = next_offset

    if sentinel_offset is None:
        warnings.append("no save-state terminator found before stream end")

    trailing_bytes = max(0, len(data) - offset)
    return DumpResult(
        path=str(path),
        file_size=len(data),
        save_counter=save_counter,
        stream_length_bytes=stream_length_bytes,
        stream_end_offset=stream_end_offset,
        parsed_end_offset=offset,
        sentinel_offset=sentinel_offset,
        trailing_bytes=trailing_bytes,
        sections=sections,
        warnings=warnings,
    )


def fmt_bytes(value: int) -> str:
    if value >= 1024 * 1024 and value % (1024 * 1024) == 0:
        return f"{value // (1024 * 1024)} MiB"
    if value >= 1024 and value % 1024 == 0:
        return f"{value // 1024} KiB"
    return f"{value} B"


def parse_section_selector(selector: str, section_names: dict[int, str]) -> int:
    try:
        return int(selector, 0)
    except ValueError:
        pass

    wanted = selector.upper()
    for index, name in section_names.items():
        if name.upper() == wanted or f"SSIDX_{name}".upper() == wanted:
            return index
    raise ValueError(f"unknown section selector {selector!r}; use an index like 8/0x8 or a name like ICS2115")


def find_section(result: DumpResult, selector: str, section_names: dict[int, str]) -> Section:
    index = parse_section_selector(selector, section_names)
    matches = [section for section in result.sections if section.index == index]
    if not matches:
        raise ValueError(f"section {selector!r} / index {index} was not found in {result.path}")
    if len(matches) > 1:
        raise ValueError(f"section index {index} appears {len(matches)} times in {result.path}; parser/layout may need updating")
    return matches[0]


def hexdump(data: bytes, base_offset: int = 0, bytes_per_line: int = 16) -> str:
    lines: list[str] = []
    for offset in range(0, len(data), bytes_per_line):
        chunk = data[offset:offset + bytes_per_line]
        hex_part = " ".join(f"{byte:02x}" for byte in chunk)
        hex_part = hex_part.ljust(bytes_per_line * 3 - 1)
        ascii_part = "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in chunk)
        lines.append(f"{base_offset + offset:08x}  {hex_part}  |{ascii_part}|")
    return "\n".join(lines)


def section_payload(path: Path, section: Section, include_stored: bool) -> bytes:
    data = path.read_bytes()
    length = section.stored_bytes if include_stored else section.logical_bytes
    return data[section.data_offset:section.data_offset + length]


def dump_section_data(path: Path, result: DumpResult, section: Section, output: Path | None, include_stored: bool) -> None:
    payload = section_payload(path, section, include_stored)
    length_name = "stored" if include_stored else "logical"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(payload)
        print(
            f"Wrote {len(payload)} {length_name} bytes from section "
            f"{section.index} {section.name} to {output}"
        )
        return

    print()
    print(
        f"Data dump: section {section.index} {section.name}, "
        f"{len(payload)} {length_name} bytes, data offset 0x{section.data_offset:08x}"
    )
    print(hexdump(payload, section.data_offset))


def print_text(result: DumpResult) -> None:
    print(f"Save state: {result.path}")
    print(f"File size:  {result.file_size} bytes ({fmt_bytes(result.file_size)})")
    print(f"Counter:    {result.save_counter}")
    print(f"Stream len: {result.stream_length_bytes} bytes ({fmt_bytes(result.stream_length_bytes)})")
    print(f"Stream end: 0x{result.stream_end_offset:08x}")
    if result.sentinel_offset is not None:
        print(f"Terminator: 0x{result.sentinel_offset:08x}")
    else:
        print("Terminator: <missing>")
    print(f"Trailing:   {result.trailing_bytes} bytes")
    print()

    header = (
        f"{'Off':>10} {'Idx':>3} {'Name':<14} {'Width':>6} {'Count':>10} "
        f"{'Logical':>12} {'Stored':>12} {'Extra':>10} {'DataOff':>10}"
    )
    print(header)
    print("-" * len(header))
    total_logical = 0
    total_stored = 0
    for section in result.sections:
        total_logical += section.logical_bytes
        total_stored += section.stored_bytes
        extra_bytes = section.stored_bytes - section.logical_bytes
        print(
            f"0x{section.offset:08x} {section.index:3d} {section.name:<14} "
            f"{section.item_bytes * 8:5d}b {section.count:10d} "
            f"{fmt_bytes(section.logical_bytes):>12} {fmt_bytes(section.stored_bytes):>12} "
            f"{fmt_bytes(extra_bytes):>10} 0x{section.data_offset:08x}"
        )

    print("-" * len(header))
    print(f"Sections: {len(result.sections)}")
    print(f"Payload logical total: {total_logical} bytes ({fmt_bytes(total_logical)})")
    print(f"Payload stored total:  {total_stored} bytes ({fmt_bytes(total_stored)})")

    if result.warnings:
        print()
        print("Warnings:")
        for warning in result.warnings:
            print(f"- {warning}")


def result_to_jsonable(result: DumpResult) -> dict[str, Any]:
    out = asdict(result)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Dump IGSPGM .pgmstate section sizes")
    parser.add_argument("files", nargs="*", type=Path, help=".pgmstate file(s) to inspect")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text")
    parser.add_argument(
        "--dump-section",
        metavar="SECTION",
        help="Dump data for one section by index/name, e.g. 8, 0x8, ICS2115, or SSIDX_ICS2115",
    )
    parser.add_argument(
        "--dump-output",
        type=Path,
        help="Write dumped section bytes to this file instead of printing a hexdump",
    )
    parser.add_argument(
        "--dump-stored",
        action="store_true",
        help="Dump stored bytes including legacy spacer/padding; default dumps logical section data only",
    )
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT, help="Repository root for parsing rtl/system_consts.sv")
    parser.add_argument("--update-prompt", action="store_true", help="Print the maintenance/update prompt and exit")
    parser.add_argument("--show-update-prompt", action="store_true", help="Print the maintenance/update prompt after the dump")
    args = parser.parse_args()

    if args.update_prompt:
        print(UPDATE_PROMPT)
        return 0

    if not args.files:
        parser.error("at least one .pgmstate file is required unless --update-prompt is used")

    if args.dump_output and not args.dump_section:
        parser.error("--dump-output requires --dump-section")
    if args.dump_output and len(args.files) != 1:
        parser.error("--dump-output can only be used with exactly one input file")

    section_names = load_section_names(args.repo_root.resolve())
    results = [parse_pgmstate(path, section_names) for path in args.files]

    if args.json and args.dump_section:
        parser.error("--json cannot be combined with --dump-section")

    if args.json:
        print(json.dumps([result_to_jsonable(result) for result in results], indent=2))
    else:
        for i, result in enumerate(results):
            if i:
                print()
            print_text(result)
            if args.dump_section:
                section = find_section(result, args.dump_section, section_names)
                output = args.dump_output.resolve() if args.dump_output else None
                dump_section_data(args.files[i], result, section, output, args.dump_stored)

    if args.show_update_prompt:
        print()
        print("Update prompt:")
        print(UPDATE_PROMPT)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
