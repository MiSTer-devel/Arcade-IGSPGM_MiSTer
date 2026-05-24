#include "bsp/board_api.h"
#include "pico/stdlib.h"
#include "pico/time.h"
#include "rate_measure.h"
#include "serial_audio_capture.h"
#include "capture_stream.h"
#include "tusb.h"

static void led_task(void) {
    static uint32_t last_toggle_ms;
    static bool led_state;

    uint32_t interval_ms = 250;
    if (tud_suspended()) {
        interval_ms = 2000;
    } else if (tud_mounted()) {
        interval_ms = 1000;
    }

    uint32_t now = board_millis();
    if ((now - last_toggle_ms) >= interval_ms) {
        last_toggle_ms = now;
        led_state = !led_state;
        board_led_write(led_state);
    }
}

static uint32_t build_capture_flags(void) {
    uint32_t flags = 0;
    if (rate_measure_is_valid()) {
        flags |= PGM_CAPTURE_FLAG_RATE_VALID;
    }
    if (serial_audio_capture_is_running()) {
        flags |= PGM_CAPTURE_FLAG_CAPTURE_RUNNING;
    }
    if (serial_audio_capture_get_dropped_dma_blocks() != 0u) {
        flags |= PGM_CAPTURE_FLAG_DMA_DROP;
    }
    if (serial_audio_capture_get_dropped_audio_frames() != 0u) {
        flags |= PGM_CAPTURE_FLAG_AUDIO_DROP;
    }
    if (capture_stream_get_dropped_packets() != 0u) {
        flags |= PGM_CAPTURE_FLAG_QUEUE_DROP;
    }
    if (!capture_stream_connected()) {
        flags |= PGM_CAPTURE_FLAG_NO_HOST;
    }
    if (capture_stream_get_mode() != PGM_CAPTURE_STREAM_MODE_CONTINUOUS) {
        flags |= PGM_CAPTURE_FLAG_TRIGGERED_MODE;
    }
    return flags;
}

static void status_task(void) {
    static uint32_t last_status_ms;

    uint32_t now_ms = board_millis();
    if ((now_ms - last_status_ms) < 1000u) {
        return;
    }
    last_status_ms = now_ms;

    pgm_capture_status_payload_t status = {
        .uptime_ms = now_ms,
        .rate_hz = rate_measure_get_hz(),
        .raw_rate_hz = rate_measure_get_raw_hz(),
        .edge_count = rate_measure_get_edge_count(),
        .elapsed_us = rate_measure_get_elapsed_us(),
        .idle_us = rate_measure_get_idle_us(),
        .rate_status = (uint32_t)rate_measure_get_status(),
        .ready_mask = serial_audio_capture_get_ready_mask(),
        .processed_dma_blocks = serial_audio_capture_get_processed_dma_blocks(),
        .dropped_dma_blocks = serial_audio_capture_get_dropped_dma_blocks(),
        .dropped_audio_frames = serial_audio_capture_get_dropped_audio_frames(),
        .channel_word_count = serial_audio_capture_get_channel_word_count(),
        .stereo_frame_count = serial_audio_capture_get_stereo_frame_count(),
        .nonzero_sample_count = serial_audio_capture_get_nonzero_sample_count(),
        .last_left_sample = serial_audio_capture_get_last_left_sample(),
        .last_right_sample = serial_audio_capture_get_last_right_sample(),
        .stream_dropped_packets = capture_stream_get_dropped_packets(),
        .stream_dropped_bytes = capture_stream_get_dropped_bytes(),
        .stream_queue_depth = capture_stream_get_queue_depth(),
        .reserved = capture_stream_get_armed_remaining(),
    };

    capture_stream_submit_status(time_us_64(), build_capture_flags(), &status);
}

int main(void) {
    board_init();

    serial_audio_capture_config_t capture_config = {
        .si_gpio = 13,
        .clk_gpio = 14,
        .lrclk_gpio = 15,
        .lrclk_low_is_left = true,
        .sample_on_rising_edge = true,
        .bits_per_sample = 16,
    };

    rate_measure_init(capture_config.lrclk_gpio);
    capture_stream_init();
    serial_audio_capture_init(&capture_config);

    tusb_rhport_init_t dev_init = {
        .role = TUSB_ROLE_DEVICE,
        .speed = TUSB_SPEED_AUTO,
    };
    tusb_init(BOARD_TUD_RHPORT, &dev_init);

    if (board_init_after_tusb) {
        board_init_after_tusb();
    }

    rate_measure_enable();
    serial_audio_capture_enable();

    while (true) {
        tud_task();
        rate_measure_task();
        serial_audio_capture_task();
        status_task();
        capture_stream_task();
        led_task();
    }

    return 0;
}
