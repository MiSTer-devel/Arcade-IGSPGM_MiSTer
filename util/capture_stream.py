#!/usr/bin/env /usr/bin/python3
import argparse
import collections
import glob
import json
import os
import select
import signal
import struct
import sys
import time
import wave
from pathlib import Path

MAGIC = 0x414D4750
HDR_FMT = "<IHHIIQIQII"
HDR_SIZE = struct.calcsize(HDR_FMT)
TYPE_AUDIO = 1
TYPE_STATUS = 2
TYPE_CONTROL = 3
STATUS_FMT = "<IIIIIIIIIIIIIIhhIIII"
CONTROL_FMT = "<IIIII"
STATUS_SIZE = struct.calcsize(STATUS_FMT)
CONTROL_SIZE = struct.calcsize(CONTROL_FMT)
POLL_S = 0.2
READ_SIZE = 4096

stop_requested = False


class StreamSource:
    def __init__(self, stream, *, live):
        self._stream = stream
        self.live = live

    def read(self, size):
        return self._stream.read(size)

    def write(self, data):
        written = self._stream.write(data)
        flush = getattr(self._stream, 'flush', None)
        if flush is not None:
            flush()
        return written

    def reset_input_buffer(self):
        reset = getattr(self._stream, 'reset_input_buffer', None)
        if reset is not None:
            reset()

    def close(self):
        self._stream.close()


class PosixSerialSource:
    live = True

    def __init__(self, port):
        import termios

        self._termios = termios
        self._fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self._old_attrs = termios.tcgetattr(self._fd)
        attrs = termios.tcgetattr(self._fd)
        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0
        attrs[4] = termios.B115200
        attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self._fd, termios.TCSANOW, attrs)
        self._set_modem_lines()

    def _set_modem_lines(self):
        try:
            import fcntl

            termios = self._termios
            if hasattr(termios, 'TIOCMBIS') and hasattr(termios, 'TIOCMBIC'):
                if hasattr(termios, 'TIOCM_DTR'):
                    fcntl.ioctl(self._fd, termios.TIOCMBIS, struct.pack('I', termios.TIOCM_DTR))
                if hasattr(termios, 'TIOCM_RTS'):
                    fcntl.ioctl(self._fd, termios.TIOCMBIC, struct.pack('I', termios.TIOCM_RTS))
        except OSError:
            pass

    def read(self, size):
        ready, _, _ = select.select([self._fd], [], [], POLL_S)
        if not ready:
            return b''
        try:
            return os.read(self._fd, size)
        except BlockingIOError:
            return b''

    def write(self, data):
        return os.write(self._fd, data)

    def reset_input_buffer(self):
        try:
            import termios
            termios.tcflush(self._fd, termios.TCIFLUSH)
        except OSError:
            pass

    def close(self):
        try:
            self._termios.tcsetattr(self._fd, self._termios.TCSANOW, self._old_attrs)
        finally:
            os.close(self._fd)


class SerialSource(PosixSerialSource):
    """Default live serial source.

    Use the lean POSIX fd implementation by default; it has lower latency for
    this high-rate USB CDC packet stream than pyserial's wrapper path.
    """

    pass


class FileSource(StreamSource):
    def __init__(self, path):
        super().__init__(Path(path).open('rb'), live=False)


def on_signal(signum, frame):
    del signum, frame
    global stop_requested
    stop_requested = True


def find_ports():
    return sorted(glob.glob('/dev/cu.usbmodem*')) + sorted(glob.glob('/dev/tty.usbmodem*'))


def choose_port(explicit):
    if explicit:
        return explicit
    ports = find_ports()
    return ports[0] if ports else None


def deadline_reached(deadline):
    return deadline is not None and time.time() >= deadline


def sync_to_magic(source, buf, deadline=None):
    magic = struct.pack('<I', MAGIC)
    while True:
        if deadline_reached(deadline):
            return False
        idx = buf.find(magic)
        if idx >= 0:
            if idx:
                del buf[:idx]
            return True

        data = source.read(READ_SIZE)
        if not data:
            if stop_requested or not source.live:
                return False
            continue
        buf.extend(data)


def read_exact(source, buf, size, deadline=None):
    while len(buf) < size:
        if deadline_reached(deadline):
            return None
        data = source.read(READ_SIZE)
        if not data:
            if stop_requested or not source.live:
                return None
            continue
        buf.extend(data)
    out = bytes(buf[:size])
    del buf[:size]
    return out


def decode_header(data):
    fields = struct.unpack(HDR_FMT, data)
    return {
        'magic': fields[0],
        'version': fields[1],
        'type': fields[2],
        'payload_bytes': fields[3],
        'block_seq': fields[4],
        'frame_start': fields[5],
        'frame_count': fields[6],
        't_us': fields[7],
        'raw_lrclk_hz': fields[8],
        'flags': fields[9],
    }


def decode_status(data):
    fields = struct.unpack(STATUS_FMT, data)
    keys = [
        'uptime_ms', 'rate_hz', 'raw_rate_hz', 'edge_count', 'elapsed_us', 'idle_us',
        'rate_status', 'ready_mask', 'processed_dma_blocks', 'dropped_dma_blocks',
        'dropped_audio_frames', 'channel_word_count', 'stereo_frame_count',
        'nonzero_sample_count', 'last_left_sample', 'last_right_sample',
        'stream_dropped_packets', 'stream_dropped_bytes', 'stream_queue_depth', 'reserved'
    ]
    return dict(zip(keys, fields))


def decode_control(data):
    fields = struct.unpack(CONTROL_FMT, data)
    keys = ['cmd', 'seq', 'status', 'mode', 'value']
    return dict(zip(keys, fields))


def final_sample_rate(counter, fallback):
    if not counter:
        return fallback
    return counter.most_common(1)[0][0]


def build_wav(raw_path, wav_path, sample_rate, frame_count):
    with raw_path.open('rb') as src, wave.open(str(wav_path), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        remaining = frame_count * 4
        while remaining > 0:
            chunk = src.read(min(65536, remaining))
            if not chunk:
                break
            wav.writeframes(chunk)
            remaining -= len(chunk)


def open_source(args):
    if args.input:
        return FileSource(args.input), str(Path(args.input).resolve())

    port = choose_port(args.port)
    if not port:
        print('No serial port found', file=sys.stderr)
        return None, None

    if not getattr(args, 'print_sample_changes', False):
        print(f'Opening {port}', flush=True)
    return SerialSource(port), port


def main():
    parser = argparse.ArgumentParser(
        description='Capture or decode native PGM audio stream from USB CDC hardware or simulator binary output'
    )
    parser.add_argument('output', help='Output WAV path')
    parser.add_argument('--port', help='Serial port to use for hardware capture')
    parser.add_argument('--input', help='Read packet stream from a binary file instead of a serial port')
    parser.add_argument('--duration', type=float, default=10.0,
                        help='Capture duration in seconds for serial mode (default: 10)')
    parser.add_argument('--endless', action='store_true',
                        help='In serial mode, capture until Ctrl-C instead of stopping after --duration')
    parser.add_argument('--sample-rate', type=int, help='Override WAV sample rate metadata')
    parser.add_argument('--summary-json', help='Optional path for summary JSON output')
    parser.add_argument('--strict', action='store_true', help='Exit non-zero if packet/frame gaps are detected')
    parser.add_argument('--print-sample-changes', action='store_true',
                        help='Print left/right sample values whenever either channel changes')
    args = parser.parse_args()

    if args.input and args.port:
        print('Use either --input or --port, not both', file=sys.stderr)
        return 1

    output_path = Path(args.output)
    raw_path = output_path.with_suffix(output_path.suffix + '.raw')
    jsonl_path = output_path.with_suffix(output_path.suffix + '.jsonl')
    summary_path = Path(args.summary_json) if args.summary_json else output_path.with_suffix(output_path.suffix + '.summary.json')
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if hasattr(signal, 'SIGPIPE'):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    source, source_name = open_source(args)
    if source is None:
        return 1

    buf = bytearray()
    rate_counter = collections.Counter()
    total_frames = 0
    audio_packets = 0
    status_packets = 0
    malformed_status_packets = 0
    control_packets = 0
    first_packet_time = None
    first_audio_time = None
    deadline = None if args.input or args.endless else (time.time() + args.duration if args.duration > 0 else None)
    expected_block_seq = None
    expected_frame_start = None
    block_gap_count = 0
    frame_gap_count = 0
    block_gap_frames = 0
    status_drop_reports = 0
    max_queue_depth = 0
    latest_status = None
    last_printed_sample = None

    with raw_path.open('wb') as raw_file, jsonl_path.open('w', encoding='utf-8') as jsonl:
        try:
            while not stop_requested:
                if deadline is not None and time.time() >= deadline:
                    break
                if not sync_to_magic(source, buf, deadline):
                    break
                hdr_data = read_exact(source, buf, HDR_SIZE, deadline)
                if hdr_data is None:
                    break
                hdr = decode_header(hdr_data)
                if hdr['magic'] != MAGIC:
                    continue
                payload = read_exact(source, buf, hdr['payload_bytes'], deadline)
                if payload is None:
                    break

                now = time.time()
                if first_packet_time is None:
                    first_packet_time = now

                record = {'header': hdr}
                if expected_block_seq is not None and hdr['block_seq'] != expected_block_seq:
                    block_gap_count += 1
                    record['block_seq_gap'] = [expected_block_seq, hdr['block_seq']]
                expected_block_seq = hdr['block_seq'] + 1

                if hdr['type'] == TYPE_AUDIO:
                    if first_audio_time is None:
                        first_audio_time = now
                    audio_packets += 1
                    raw_file.write(payload)
                    if args.print_sample_changes:
                        for sample_index in range(0, len(payload) - 3, 4):
                            left, right = struct.unpack_from('<hh', payload, sample_index)
                            sample = (left, right)
                            if sample != last_printed_sample:
                                print(
                                    f'frame={hdr["frame_start"] + sample_index // 4} '
                                    f'L={left} R={right}',
                                    flush=True,
                                )
                                last_printed_sample = sample
                    total_frames += hdr['frame_count']
                    if hdr['raw_lrclk_hz']:
                        rate_counter[hdr['raw_lrclk_hz']] += hdr['frame_count']
                    if expected_frame_start is not None and hdr['frame_start'] != expected_frame_start:
                        frame_gap_count += 1
                        gap = hdr['frame_start'] - expected_frame_start
                        if gap > 0:
                            block_gap_frames += gap
                        record['frame_gap'] = [expected_frame_start, hdr['frame_start']]
                    expected_frame_start = hdr['frame_start'] + hdr['frame_count']
                elif hdr['type'] == TYPE_STATUS:
                    status_packets += 1
                    if len(payload) == STATUS_SIZE:
                        status = decode_status(payload)
                        latest_status = status
                        max_queue_depth = max(max_queue_depth, status['stream_queue_depth'])
                        if status['stream_dropped_packets']:
                            status_drop_reports += 1
                        record['status'] = status
                    else:
                        malformed_status_packets += 1
                        record['status_error'] = f'unexpected status payload {len(payload)}'
                elif hdr['type'] == TYPE_CONTROL:
                    control_packets += 1
                    if len(payload) == CONTROL_SIZE:
                        record['control'] = decode_control(payload)
                    else:
                        record['control_error'] = f'unexpected control payload {len(payload)}'
                else:
                    record['unknown_payload_bytes'] = len(payload)

                jsonl.write(json.dumps(record) + '\n')

                if source.live and not args.print_sample_changes and (audio_packets + status_packets) % 50 == 0:
                    ref = first_audio_time or first_packet_time or now
                    elapsed = max(now - ref, 0.001)
                    print(
                        f'packets={audio_packets + status_packets} '
                        f'audio={audio_packets} status={status_packets} control={control_packets} '
                        f'frames={total_frames} rate~={final_sample_rate(rate_counter, 33074)} '
                        f'fps={total_frames/elapsed:.1f} gaps={frame_gap_count}/{block_gap_count}',
                        flush=True,
                    )
        finally:
            source.close()

    sample_rate = args.sample_rate or final_sample_rate(rate_counter, 33074)
    build_wav(raw_path, output_path, sample_rate, total_frames)

    summary = {
        'source': source_name,
        'output_wav': str(output_path),
        'output_raw': str(raw_path),
        'output_jsonl': str(jsonl_path),
        'sample_rate': sample_rate,
        'frames': total_frames,
        'audio_packets': audio_packets,
        'status_packets': status_packets,
        'malformed_status_packets': malformed_status_packets,
        'control_packets': control_packets,
        'block_gap_count': block_gap_count,
        'frame_gap_count': frame_gap_count,
        'frame_gap_frames': block_gap_frames,
        'status_drop_reports': status_drop_reports,
        'max_queue_depth': max_queue_depth,
        'latest_status': latest_status,
        'rate_histogram': dict(rate_counter),
    }
    summary_path.write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')

    if not args.print_sample_changes:
        print(
            f'Wrote {output_path} rate={sample_rate} frames={total_frames} '
            f'audio_packets={audio_packets} status_packets={status_packets} control_packets={control_packets} '
            f'frame_gaps={frame_gap_count} block_gaps={block_gap_count}',
            flush=True,
        )
        print(f'Metadata: {jsonl_path}', flush=True)
        print(f'Summary: {summary_path}', flush=True)

    if args.strict and (block_gap_count or frame_gap_count or malformed_status_packets):
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
