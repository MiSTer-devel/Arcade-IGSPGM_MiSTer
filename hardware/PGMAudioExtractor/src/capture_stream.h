#ifndef CAPTURE_STREAM_H
#define CAPTURE_STREAM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ring_buffer.h"

#define PGM_CAPTURE_MAGIC 0x414D4750u
#define PGM_CAPTURE_PROTOCOL_VERSION 1u

typedef enum {
    PGM_CAPTURE_PACKET_TYPE_AUDIO = 1,
    PGM_CAPTURE_PACKET_TYPE_STATUS = 2,
    PGM_CAPTURE_PACKET_TYPE_CONTROL = 3,
} pgm_capture_packet_type_t;

#define PGM_CAPTURE_CONTROL_MAGIC 0x434D4750u /* 'PGMC' */

typedef enum {
    PGM_CAPTURE_CONTROL_CMD_FLUSH = 1,
    PGM_CAPTURE_CONTROL_CMD_CONTINUOUS = 2,
    PGM_CAPTURE_CONTROL_CMD_IDLE = 3,
    PGM_CAPTURE_CONTROL_CMD_ARM_FRAMES = 4,
    PGM_CAPTURE_CONTROL_CMD_ARM_BLOCKS = 5,
    PGM_CAPTURE_CONTROL_CMD_STATUS = 6,
} pgm_capture_control_cmd_t;

typedef enum {
    PGM_CAPTURE_CONTROL_STATUS_OK = 0,
    PGM_CAPTURE_CONTROL_STATUS_BAD_VERSION = 1,
    PGM_CAPTURE_CONTROL_STATUS_BAD_CMD = 2,
    PGM_CAPTURE_CONTROL_STATUS_BAD_ARG = 3,
} pgm_capture_control_status_t;

typedef enum {
    PGM_CAPTURE_STREAM_MODE_CONTINUOUS = 0,
    PGM_CAPTURE_STREAM_MODE_IDLE = 1,
    PGM_CAPTURE_STREAM_MODE_ARM_FRAMES = 2,
    PGM_CAPTURE_STREAM_MODE_ARM_BLOCKS = 3,
} pgm_capture_stream_mode_t;

typedef enum {
    PGM_CAPTURE_FLAG_RATE_VALID = 1u << 0,
    PGM_CAPTURE_FLAG_CAPTURE_RUNNING = 1u << 1,
    PGM_CAPTURE_FLAG_DMA_DROP = 1u << 2,
    PGM_CAPTURE_FLAG_AUDIO_DROP = 1u << 3,
    PGM_CAPTURE_FLAG_QUEUE_DROP = 1u << 4,
    PGM_CAPTURE_FLAG_NO_HOST = 1u << 5,
    PGM_CAPTURE_FLAG_TRIGGERED_MODE = 1u << 6,
} pgm_capture_flags_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t payload_bytes;
    uint32_t block_seq;
    uint64_t frame_start;
    uint32_t frame_count;
    uint64_t t_us;
    uint32_t raw_lrclk_hz;
    uint32_t flags;
} pgm_capture_packet_header_t;

typedef struct __attribute__((packed)) {
    uint32_t cmd;
    uint32_t seq;
    uint32_t status;
    uint32_t mode;
    uint32_t value;
} pgm_capture_control_payload_t;

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

void capture_stream_init(void);
void capture_stream_task(void);
void capture_stream_reset(void);
bool capture_stream_connected(void);
void capture_stream_submit_audio(uint64_t frame_start,
                                 uint64_t t_us,
                                 uint32_t raw_lrclk_hz,
                                 uint32_t flags,
                                 const stereo_frame_t *frames,
                                 uint32_t frame_count);
void capture_stream_submit_status(uint64_t t_us,
                                  uint32_t flags,
                                  const pgm_capture_status_payload_t *status);
uint32_t capture_stream_get_dropped_packets(void);
uint32_t capture_stream_get_dropped_bytes(void);
uint32_t capture_stream_get_queue_depth(void);
uint32_t capture_stream_get_mode(void);
uint32_t capture_stream_get_armed_remaining(void);

#endif
