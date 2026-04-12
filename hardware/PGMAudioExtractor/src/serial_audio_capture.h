#ifndef SERIAL_AUDIO_CAPTURE_H
#define SERIAL_AUDIO_CAPTURE_H

#include <stdbool.h>
#include <stdint.h>

#include "ring_buffer.h"

typedef struct {
    uint32_t clk_gpio;
    uint32_t lrclk_gpio;
    uint32_t si_gpio;
    bool lrclk_low_is_left;
    bool sample_on_rising_edge;
    uint8_t bits_per_sample;
} serial_audio_capture_config_t;

void serial_audio_capture_init(const serial_audio_capture_config_t *config, stereo_ring_buffer_t *target_buffer);
void serial_audio_capture_task(void);

#endif
