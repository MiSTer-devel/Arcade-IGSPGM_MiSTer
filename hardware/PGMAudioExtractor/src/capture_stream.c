#include "capture_stream.h"

#include <string.h>

#include "pico/time.h"
#include "tusb.h"

#define CAPTURE_STREAM_PACKET_QUEUE_LEN 32u
#define CAPTURE_STREAM_MAX_AUDIO_FRAMES 128u
#define CAPTURE_STREAM_MAX_PAYLOAD_BYTES (CAPTURE_STREAM_MAX_AUDIO_FRAMES * sizeof(stereo_frame_t))
#define CAPTURE_STREAM_MAX_PACKET_BYTES (sizeof(pgm_capture_packet_header_t) + CAPTURE_STREAM_MAX_PAYLOAD_BYTES)
#define CAPTURE_STREAM_COMMAND_BYTES 16u
#define CAPTURE_STREAM_TRIGGER_SKIP_BLOCKS 2u

typedef struct {
    uint16_t total_bytes;
    uint16_t tx_offset;
    uint8_t data[CAPTURE_STREAM_MAX_PACKET_BYTES];
} capture_stream_packet_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t cmd;
    uint32_t seq;
    uint32_t arg;
} capture_stream_command_t;

static capture_stream_packet_t packet_queue[CAPTURE_STREAM_PACKET_QUEUE_LEN];
static uint8_t queue_head;
static uint8_t queue_tail;
static uint8_t queue_count;
static bool was_connected;
static uint32_t dropped_packets;
static uint32_t dropped_bytes;
static uint32_t next_packet_seq;
static pgm_capture_stream_mode_t stream_mode;
static uint32_t armed_remaining;
static uint32_t armed_skip_blocks;
static uint8_t command_buf[CAPTURE_STREAM_COMMAND_BYTES];
static uint8_t command_len;

static inline bool queue_full(void) {
    return queue_count >= CAPTURE_STREAM_PACKET_QUEUE_LEN;
}

static inline bool queue_empty(void) {
    return queue_count == 0u;
}

static inline capture_stream_packet_t *queue_peek_head(void) {
    return queue_empty() ? NULL : &packet_queue[queue_head];
}

static inline capture_stream_packet_t *queue_peek_tail(void) {
    return queue_full() ? NULL : &packet_queue[queue_tail];
}

static inline void queue_push_complete(void) {
    queue_tail = (uint8_t)((queue_tail + 1u) % CAPTURE_STREAM_PACKET_QUEUE_LEN);
    queue_count++;
}

static inline void queue_pop(void) {
    if (queue_empty()) {
        return;
    }
    queue_head = (uint8_t)((queue_head + 1u) % CAPTURE_STREAM_PACKET_QUEUE_LEN);
    queue_count--;
}

static bool stream_ready(void) {
    return tud_mounted() && tud_cdc_connected();
}

static void clear_queue(void) {
    queue_head = 0;
    queue_tail = 0;
    queue_count = 0;
}

static void drop_packet_bytes(uint32_t bytes) {
    dropped_packets++;
    dropped_bytes += bytes;
}

static bool reserve_packet(uint16_t total_bytes, capture_stream_packet_t **packet) {
    if (!stream_ready()) {
        drop_packet_bytes(total_bytes);
        return false;
    }

    if (queue_full()) {
        drop_packet_bytes(total_bytes);
        return false;
    }

    capture_stream_packet_t *slot = queue_peek_tail();
    if (!slot) {
        drop_packet_bytes(total_bytes);
        return false;
    }

    slot->total_bytes = total_bytes;
    slot->tx_offset = 0;
    *packet = slot;
    return true;
}

static bool queue_control_response(uint32_t cmd, uint32_t seq, uint32_t status, uint32_t value) {
    uint32_t payload_bytes = (uint32_t)sizeof(pgm_capture_control_payload_t);
    uint16_t total_bytes = (uint16_t)(sizeof(pgm_capture_packet_header_t) + payload_bytes);
    capture_stream_packet_t *packet = NULL;
    if (!reserve_packet(total_bytes, &packet)) {
        return false;
    }

    pgm_capture_control_payload_t payload = {
        .cmd = cmd,
        .seq = seq,
        .status = status,
        .mode = (uint32_t)stream_mode,
        .value = value,
    };

    pgm_capture_packet_header_t header = {
        .magic = PGM_CAPTURE_MAGIC,
        .version = PGM_CAPTURE_PROTOCOL_VERSION,
        .type = PGM_CAPTURE_PACKET_TYPE_CONTROL,
        .payload_bytes = payload_bytes,
        .block_seq = next_packet_seq++,
        .frame_start = 0,
        .frame_count = 0,
        .t_us = time_us_64(),
        .raw_lrclk_hz = 0,
        .flags = stream_mode == PGM_CAPTURE_STREAM_MODE_CONTINUOUS ? 0 : PGM_CAPTURE_FLAG_TRIGGERED_MODE,
    };

    memcpy(packet->data, &header, sizeof(header));
    memcpy(packet->data + sizeof(header), &payload, sizeof(payload));
    queue_push_complete();
    return true;
}

static void process_command(const capture_stream_command_t *cmd) {
    uint32_t status = PGM_CAPTURE_CONTROL_STATUS_OK;
    uint32_t value = cmd->arg;

    if (cmd->version != PGM_CAPTURE_PROTOCOL_VERSION) {
        queue_control_response(cmd->cmd, cmd->seq, PGM_CAPTURE_CONTROL_STATUS_BAD_VERSION, cmd->version);
        return;
    }

    switch (cmd->cmd) {
        case PGM_CAPTURE_CONTROL_CMD_FLUSH:
            clear_queue();
            value = queue_count;
            break;
        case PGM_CAPTURE_CONTROL_CMD_CONTINUOUS:
            clear_queue();
            stream_mode = PGM_CAPTURE_STREAM_MODE_CONTINUOUS;
            armed_remaining = 0;
            armed_skip_blocks = 0;
            break;
        case PGM_CAPTURE_CONTROL_CMD_IDLE:
            clear_queue();
            stream_mode = PGM_CAPTURE_STREAM_MODE_IDLE;
            armed_remaining = 0;
            armed_skip_blocks = 0;
            break;
        case PGM_CAPTURE_CONTROL_CMD_ARM_FRAMES:
            if (cmd->arg == 0 || cmd->arg > CAPTURE_STREAM_MAX_AUDIO_FRAMES) {
                status = PGM_CAPTURE_CONTROL_STATUS_BAD_ARG;
                value = CAPTURE_STREAM_MAX_AUDIO_FRAMES;
                break;
            }
            clear_queue();
            stream_mode = PGM_CAPTURE_STREAM_MODE_ARM_FRAMES;
            armed_remaining = cmd->arg;
            armed_skip_blocks = CAPTURE_STREAM_TRIGGER_SKIP_BLOCKS;
            break;
        case PGM_CAPTURE_CONTROL_CMD_ARM_BLOCKS:
            if (cmd->arg == 0 || cmd->arg > CAPTURE_STREAM_PACKET_QUEUE_LEN) {
                status = PGM_CAPTURE_CONTROL_STATUS_BAD_ARG;
                value = CAPTURE_STREAM_PACKET_QUEUE_LEN;
                break;
            }
            clear_queue();
            stream_mode = PGM_CAPTURE_STREAM_MODE_ARM_BLOCKS;
            armed_remaining = cmd->arg;
            armed_skip_blocks = CAPTURE_STREAM_TRIGGER_SKIP_BLOCKS;
            break;
        case PGM_CAPTURE_CONTROL_CMD_STATUS:
            value = armed_remaining;
            break;
        default:
            status = PGM_CAPTURE_CONTROL_STATUS_BAD_CMD;
            break;
    }

    queue_control_response(cmd->cmd, cmd->seq, status, value);
}

static void reset_command_parser(void) {
    command_len = 0;
}

static void command_parser_byte(uint8_t b) {
    const uint8_t magic[4] = {'P', 'G', 'M', 'C'};

    if (command_len < 4u) {
        if (b == magic[command_len]) {
            command_buf[command_len++] = b;
        } else {
            command_len = (b == magic[0]) ? 1u : 0u;
            if (command_len) {
                command_buf[0] = b;
            }
        }
        return;
    }

    command_buf[command_len++] = b;
    if (command_len >= CAPTURE_STREAM_COMMAND_BYTES) {
        capture_stream_command_t cmd;
        memcpy(&cmd, command_buf, sizeof(cmd));
        process_command(&cmd);
        command_len = 0;
    }
}

static void poll_commands(void) {
    while (tud_cdc_available() > 0u) {
        uint8_t buf[64];
        uint32_t count = tud_cdc_read(buf, sizeof(buf));
        for (uint32_t i = 0; i < count; ++i) {
            command_parser_byte(buf[i]);
        }
    }
}

static uint32_t audio_frames_to_submit(uint32_t frame_count) {
    if (stream_mode == PGM_CAPTURE_STREAM_MODE_IDLE) {
        return 0;
    }

    if (stream_mode == PGM_CAPTURE_STREAM_MODE_CONTINUOUS) {
        return frame_count;
    }

    if (armed_skip_blocks != 0u) {
        armed_skip_blocks--;
        return 0;
    }

    if (armed_remaining == 0u) {
        stream_mode = PGM_CAPTURE_STREAM_MODE_IDLE;
        return 0;
    }

    if (stream_mode == PGM_CAPTURE_STREAM_MODE_ARM_BLOCKS) {
        armed_remaining--;
        if (armed_remaining == 0u) {
            stream_mode = PGM_CAPTURE_STREAM_MODE_IDLE;
        }
        return frame_count;
    }

    if (stream_mode == PGM_CAPTURE_STREAM_MODE_ARM_FRAMES) {
        uint32_t emit_count = frame_count < armed_remaining ? frame_count : armed_remaining;
        armed_remaining -= emit_count;
        if (armed_remaining == 0u) {
            stream_mode = PGM_CAPTURE_STREAM_MODE_IDLE;
        }
        return emit_count;
    }

    return 0;
}

void capture_stream_init(void) {
    queue_head = 0;
    queue_tail = 0;
    queue_count = 0;
    was_connected = false;
    dropped_packets = 0;
    dropped_bytes = 0;
    next_packet_seq = 0;
    stream_mode = PGM_CAPTURE_STREAM_MODE_CONTINUOUS;
    armed_remaining = 0;
    armed_skip_blocks = 0;
    reset_command_parser();
}

void capture_stream_reset(void) {
    clear_queue();
}

bool capture_stream_connected(void) {
    return stream_ready();
}

void capture_stream_submit_audio(uint64_t frame_start,
                                 uint64_t t_us,
                                 uint32_t raw_lrclk_hz,
                                 uint32_t flags,
                                 const stereo_frame_t *frames,
                                 uint32_t frame_count) {
    if (!frames || frame_count == 0u || frame_count > CAPTURE_STREAM_MAX_AUDIO_FRAMES) {
        return;
    }

    uint32_t submit_frames = audio_frames_to_submit(frame_count);
    if (submit_frames == 0u) {
        return;
    }

    if (stream_mode != PGM_CAPTURE_STREAM_MODE_CONTINUOUS) {
        flags |= PGM_CAPTURE_FLAG_TRIGGERED_MODE;
    }

    uint32_t payload_bytes = submit_frames * (uint32_t)sizeof(stereo_frame_t);
    uint16_t total_bytes = (uint16_t)(sizeof(pgm_capture_packet_header_t) + payload_bytes);
    capture_stream_packet_t *packet = NULL;
    if (!reserve_packet(total_bytes, &packet)) {
        return;
    }

    pgm_capture_packet_header_t header = {
        .magic = PGM_CAPTURE_MAGIC,
        .version = PGM_CAPTURE_PROTOCOL_VERSION,
        .type = PGM_CAPTURE_PACKET_TYPE_AUDIO,
        .payload_bytes = payload_bytes,
        .block_seq = next_packet_seq++,
        .frame_start = frame_start,
        .frame_count = submit_frames,
        .t_us = t_us,
        .raw_lrclk_hz = raw_lrclk_hz,
        .flags = flags,
    };

    memcpy(packet->data, &header, sizeof(header));
    memcpy(packet->data + sizeof(header), frames, payload_bytes);
    queue_push_complete();
}

void capture_stream_submit_status(uint64_t t_us,
                                  uint32_t flags,
                                  const pgm_capture_status_payload_t *status) {
    if (!status || stream_mode != PGM_CAPTURE_STREAM_MODE_CONTINUOUS) {
        return;
    }

    uint32_t payload_bytes = (uint32_t)sizeof(*status);
    uint16_t total_bytes = (uint16_t)(sizeof(pgm_capture_packet_header_t) + payload_bytes);
    capture_stream_packet_t *packet = NULL;
    if (!reserve_packet(total_bytes, &packet)) {
        return;
    }

    pgm_capture_packet_header_t header = {
        .magic = PGM_CAPTURE_MAGIC,
        .version = PGM_CAPTURE_PROTOCOL_VERSION,
        .type = PGM_CAPTURE_PACKET_TYPE_STATUS,
        .payload_bytes = payload_bytes,
        .block_seq = next_packet_seq++,
        .frame_start = 0,
        .frame_count = 0,
        .t_us = t_us,
        .raw_lrclk_hz = status->raw_rate_hz,
        .flags = flags,
    };

    memcpy(packet->data, &header, sizeof(header));
    memcpy(packet->data + sizeof(header), status, sizeof(*status));
    queue_push_complete();
}

void capture_stream_task(void) {
    bool connected = stream_ready();
    if (!connected) {
        if (was_connected) {
            clear_queue();
        }
        was_connected = false;
        return;
    }

    was_connected = true;
    poll_commands();

    capture_stream_packet_t *packet = queue_peek_head();
    if (!packet) {
        return;
    }

    uint32_t remaining = (uint32_t)packet->total_bytes - packet->tx_offset;
    if (remaining == 0u) {
        queue_pop();
        return;
    }

    uint32_t writable = tud_cdc_write_available();
    if (writable == 0u) {
        return;
    }

    uint32_t chunk = remaining < writable ? remaining : writable;
    uint32_t written = tud_cdc_write(packet->data + packet->tx_offset, chunk);
    packet->tx_offset = (uint16_t)(packet->tx_offset + written);
    tud_cdc_write_flush();

    if (packet->tx_offset >= packet->total_bytes) {
        queue_pop();
    }
}

uint32_t capture_stream_get_dropped_packets(void) {
    return dropped_packets;
}

uint32_t capture_stream_get_dropped_bytes(void) {
    return dropped_bytes;
}

uint32_t capture_stream_get_queue_depth(void) {
    return queue_count;
}

uint32_t capture_stream_get_mode(void) {
    return (uint32_t)stream_mode;
}

uint32_t capture_stream_get_armed_remaining(void) {
    return armed_remaining;
}
