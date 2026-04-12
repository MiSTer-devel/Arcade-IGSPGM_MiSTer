#include "bsp/board_api.h"
#include "pico/stdlib.h"
#include <stdio.h>
#include "rate_measure.h"
#include "serial_audio_capture.h"
#include "tusb.h"
#include "usb_audio.h"

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

int main(void) {
    board_init();

    serial_audio_capture_config_t capture_config = {
        .clk_gpio = 13,
        .lrclk_gpio = 14,
        .si_gpio = 15,
        .lrclk_low_is_left = true,
        .sample_on_rising_edge = true,
        .bits_per_sample = 16,
    };

    rate_measure_init(capture_config.lrclk_gpio);
    usb_audio_init();
    serial_audio_capture_init(&capture_config, usb_audio_get_capture_ring_buffer());

    tusb_rhport_init_t dev_init = {
        .role = TUSB_ROLE_DEVICE,
        .speed = TUSB_SPEED_AUTO,
    };
    tusb_init(BOARD_TUD_RHPORT, &dev_init);

    if (board_init_after_tusb) {
        board_init_after_tusb();
    }

    stdio_init_all();

    printf("PGMAudioExtractor starting\r\n");

    while (true) {
        static uint32_t last_log_ms;
        static bool rate_measure_started;

        tud_task();

        if (!rate_measure_started && board_millis() >= 3000) {
            rate_measure_enable();
            rate_measure_started = true;
            printf("rate_measure enabled on LRCLK gpio %lu\r\n", (unsigned long)capture_config.lrclk_gpio);
        }

        rate_measure_task();
        serial_audio_capture_task();
        usb_audio_task();
        led_task();

        uint32_t now = board_millis();
        if ((now - last_log_ms) >= 1000) {
            last_log_ms = now;
            printf("sample_rate=%lu valid=%u mounted=%u suspended=%u\r\n",
                   (unsigned long)usb_audio_get_current_sample_rate(),
                   (unsigned)rate_measure_is_valid(),
                   (unsigned)tud_mounted(),
                   (unsigned)tud_suspended());
        }
    }

    return 0;
}
