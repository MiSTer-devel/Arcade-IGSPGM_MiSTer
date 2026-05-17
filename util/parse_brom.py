#!/usr/bin/env python3
"""Parse PGM B-ROM (sprite mask ROM) to find Start/Mask/End blocks.

Format (16-bit LE words):
  START_LOW, START_HIGH, [mask data words...], END_HIGH, END_LOW

  start_addr = (START_HIGH << 16) | START_LOW
  end_addr   = (END_HIGH << 16) | END_LOW
  end_addr   = start_addr + zero_bits_in_data * 4 / 3
"""

import struct
import argparse


def zero_bits(w):
    return 16 - bin(w).count('1')


def parse_blocks(words, tolerance=5, min_data_words=10, max_data_words=5000):
    blocks = []
    pos = 0
    N = len(words)
    failures = []

    while pos + 3 < N:
        start_low = words[pos]
        start_high = words[pos + 1]
        start_addr = (start_high << 16) | start_low

        data_start = pos + 2
        zeros = 0
        found = False

        for i in range(data_start, min(data_start + max_data_words, N - 2)):
            zeros += zero_bits(words[i])
            data_words = i - data_start + 1

            if data_words < min_data_words:
                continue

            expected_end = start_addr + (zeros * 4 + 2) // 3
            candidate_end = (words[i + 1] << 16) | words[i + 2]

            if abs(candidate_end - expected_end) > tolerance:
                continue

            # Validate: next start address should be close to this end address
            if i + 4 < N:
                next_start = (words[i + 4] << 16) | words[i + 3]
                if abs(next_start - candidate_end) > tolerance:
                    continue

            blocks.append({
                'start_addr': start_addr,
                'end_addr': candidate_end,
                'data_words': data_words,
                'zero_bits': zeros,
                'file_offset': pos * 2,
                'start_word': pos,
                'end_word': i + 1,
            })
            pos = i + 3  # skip past END_HIGH, END_LOW to next START_LOW
            found = True
            break

        if not found:
            failures.append((pos, start_addr))
            pos += 1  # advance by one word and retry

    return blocks, failures


def main():
    parser = argparse.ArgumentParser(description='Parse PGM B-ROM mask blocks')
    parser.add_argument('files', nargs='+', help='B-ROM file path(s), concatenated in order')
    parser.add_argument('--tolerance', type=int, default=10,
                        help='Address match tolerance (default: 10)')
    parser.add_argument('--min-data', type=int, default=1,
                        help='Minimum data words before checking for end (default: 1)')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Show detailed block info')
    args = parser.parse_args()

    data = b''
    for path in args.files:
        with open(path, 'rb') as f:
            data += f.read()

    words = struct.unpack('<' + 'H' * (len(data) // 2), data)
    if len(args.files) == 1:
        print(f'File: {args.files[0]} ({len(data)} bytes, {len(words)} words)')
    else:
        print(f'Files: {", ".join(args.files)} ({len(data)} bytes total, {len(words)} words)')
    print()

    blocks, failures = parse_blocks(words, tolerance=args.tolerance,
                                     min_data_words=args.min_data)

    print(f'{"Blk":>4} {"Start Addr":>11} {"End Addr":>11} {"Diff":>7} '
          f'{"Data Words":>11} {"Zero Bits":>10} '
          f'{"File Offset":>12}')
    print('-' * 80)

    for i, b in enumerate(blocks):
        print(f'{i:4d} 0x{b["start_addr"]:08x} 0x{b["end_addr"]:08x} '
              f'{b["end_addr"] - b["start_addr"]:7d} '
              f'{b["data_words"]:11d} {b["zero_bits"]:10d} '
              f'0x{b["file_offset"]:08x}')
        if args.verbose:
            expected = b['start_addr'] + (b['zero_bits'] * 4 + 2) // 3
            print(f'       words=[{b["start_word"]}..{b["end_word"]+1}] '
                  f'expected_end=0x{expected:08x} err={b["end_addr"] - expected:+d}')

    if blocks:
        print()
        print(f'Total: {len(blocks)} blocks')
        print(f'Address range: 0x{blocks[0]["start_addr"]:06x} - 0x{blocks[-1]["end_addr"]:06x}')
        last = blocks[-1]
        end_byte = (last['end_word'] + 2) * 2
        print(f'File coverage: {end_byte} bytes of {len(data)} '
              f'({end_byte * 100 / len(data):.1f}%)')
        remaining = len(data) - end_byte
        if remaining > 0:
            print(f'Unparsed: {remaining} bytes remaining after last block')
        if failures:
            print(f'Skipped {len(failures)} positions where no block was found')


if __name__ == '__main__':
    main()
