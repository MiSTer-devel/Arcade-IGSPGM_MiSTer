#include "serial_audio_capture.h"

#include <string.h>

#include "pico/stdlib.h"
#include "serial_audio_capture.pio.h"

static serial_audio_capture_config_t capture_config;
static stereo_ring_buffer_t *capture_buffer;

void serial_audio_capture_init(const serial_audio_capture_config_t *config, stereo_ring_buffer_t *target_buffer) {
    capture_config = *config;
    capture_buffer = target_buffer;

    gpio_init(capture_config.clk_gpio);
    gpio_set_dir(capture_config.clk_gpio, GPIO_IN);
    gpio_init(capture_config.lrclk_gpio);
    gpio_set_dir(capture_config.lrclk_gpio, GPIO_IN);
    gpio_init(capture_config.si_gpio);
    gpio_set_dir(capture_config.si_gpio, GPIO_IN);

    (void)serial_audio_capture_program_get_default_config(0);
}

void serial_audio_capture_task(void) {
    (void)capture_buffer;
    // TODO: Implement PIO + DMA capture for the external backward-justified serial stream.
}
