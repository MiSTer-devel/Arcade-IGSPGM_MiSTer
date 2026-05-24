# CDC Capture Protocol

PGMAudioExtractor streams native-rate audio over USB CDC as binary packets.

All fields are little-endian.

## Packet framing

Each packet is:
- a fixed header
- followed immediately by `payload_bytes` bytes of payload

Header C definition:

```c
typedef struct __attribute__((packed)) {
    uint32_t magic;        // 'PGMA' = 0x414D4750
    uint16_t version;      // currently 1
    uint16_t type;         // 1 = audio, 2 = status
    uint32_t payload_bytes;
    uint32_t block_seq;
    uint64_t frame_start;
    uint32_t frame_count;
    uint64_t t_us;
    uint32_t raw_lrclk_hz;
    uint32_t flags;
} pgm_capture_packet_header_t;
```

## Common header fields

- `magic`: sync word used to recover framing
- `version`: protocol version
- `type`: payload type
- `payload_bytes`: number of bytes after the header
- `block_seq`: monotonically increasing packet/block sequence number
- `frame_start`: first stereo frame index represented by this packet
- `frame_count`: number of stereo frames represented by this packet
- `t_us`: `time_us_64()` timestamp captured on-device when the packet/block was emitted
- `raw_lrclk_hz`: current unsnapped measured LRCLK rate in Hz, or `0` when unavailable
- `flags`: status bitfield

## Packet types

### Type 1: audio block

Payload is raw interleaved stereo PCM frames:

```c
typedef struct {
    int16_t left;
    int16_t right;
} stereo_frame_t;
```

For audio packets:
- `payload_bytes = frame_count * 4`
- `frame_start` and `frame_count` define the exact sample range in the capture timeline

### Type 2: status

Payload C definition:

```c
typedef struct __attribute__((packed)) {
    uint32_t uptime_ms;
    uint32_t rate_hz;
    uint32_t raw_rate_hz;
    uint32_t edge_count;
    uint32_t elapsed_us;
    uint32_t idle_us;
    uint32_t rate_status;
    uint32_t ready_mask;
    uint32_t processed_dma_blocks;
    uint32_t dropped_dma_blocks;
    uint32_t dropped_audio_frames;
    uint32_t channel_word_count;
    uint32_t stereo_frame_count;
    uint32_t nonzero_sample_count;
    int16_t last_left_sample;
    int16_t last_right_sample;
    uint32_t stream_dropped_packets;
    uint32_t stream_dropped_bytes;
    uint32_t stream_queue_depth;
    uint32_t reserved;
} pgm_capture_status_payload_t;
```

Status packets provide periodic health/diagnostic information and do not contribute audio samples.

### Type 3: control ACK

Control ACK packets are emitted in response to host commands written to the same CDC serial endpoint. Payload C definition:

```c
typedef struct __attribute__((packed)) {
    uint32_t cmd;
    uint32_t seq;
    uint32_t status;
    uint32_t mode;
    uint32_t value;
} pgm_capture_control_payload_t;
```

Host command frame, written host-to-device:

```c
typedef struct __attribute__((packed)) {
    uint32_t magic;    // 'PGMC' = 0x434d4750
    uint16_t version;  // currently 1
    uint16_t cmd;
    uint32_t seq;
    uint32_t arg;
} pgm_capture_control_command_t;
```

Commands:

- `1` `FLUSH`: clear firmware transmit queue; keep current mode.
- `2` `CONTINUOUS`: clear queue and resume normal continuous streaming.
- `3` `IDLE`: clear queue and stop queueing audio/status packets.
- `4` `ARM_FRAMES`: clear queue, discard a small number of internal DMA blocks, then send the next `arg` stereo frames and return to idle.
- `5` `ARM_BLOCKS`: clear queue, discard a small number of internal DMA blocks, then send the next `arg` audio blocks and return to idle.
- `6` `STATUS`: return current control state in a control ACK.

Continuous streaming remains the power-on/default mode. Triggered commands are intended for low-latency register-sweep tests where stale host/USB buffered audio must be avoided without closing and reopening the serial port.

## Flags

Current flag definitions:

- `1 << 0` `PGM_CAPTURE_FLAG_RATE_VALID`
- `1 << 1` `PGM_CAPTURE_FLAG_CAPTURE_RUNNING`
- `1 << 2` `PGM_CAPTURE_FLAG_DMA_DROP`
- `1 << 3` `PGM_CAPTURE_FLAG_AUDIO_DROP`
- `1 << 4` `PGM_CAPTURE_FLAG_QUEUE_DROP`
- `1 << 5` `PGM_CAPTURE_FLAG_NO_HOST`

## Timeline model

The primary timing model is:
- sample values from audio payloads
- monotonically increasing `frame_start` / `frame_count`

`t_us` is an anchor timestamp for block emission, not a per-sample timestamp.

## Integrity checking

The host should verify:
- `block_seq` continuity
- `frame_start` continuity across audio packets
- absence of diagnostic drop flags when lossless capture is desired

The provided `utils/capture_stream.py` receiver records packet metadata to JSONL and summarizes packet/frame gaps at the end of capture. It can read either the live CDC stream from the capture hardware or a simulator-produced binary packet file.
