#include "rate_measure.h"

#include "hardware/gpio.h"
#include "pico/time.h"

#ifndef PGM_AUDIO_MIN_SAMPLE_RATE
#define PGM_AUDIO_MIN_SAMPLE_RATE 33800u
#endif

#ifndef PGM_AUDIO_MAX_SAMPLE_RATE
#define PGM_AUDIO_MAX_SAMPLE_RATE 44100u
#endif

#ifndef PGM_AUDIO_NOMINAL_SAMPLE_RATE
#define PGM_AUDIO_NOMINAL_SAMPLE_RATE 44100u
#endif

static uint32_t current_rate_hz;
static bool current_rate_valid;
static uint32_t measured_gpio;
static volatile uint32_t last_edge_us;
static volatile uint32_t filtered_period_q8_us;
static volatile uint32_t edge_count;
static bool irq_enabled;

static void rate_measure_gpio_irq(uint gpio, uint32_t events) {
    if (gpio != measured_gpio || !(events & GPIO_IRQ_EDGE_RISE)) {
        return;
    }

    uint32_t now_us = time_us_32();
    if (last_edge_us != 0) {
        uint32_t period_us = now_us - last_edge_us;
        if (period_us != 0) {
            uint32_t period_q8_us = period_us << 8;
            if (filtered_period_q8_us == 0) {
                filtered_period_q8_us = period_q8_us;
            } else {
                filtered_period_q8_us = (filtered_period_q8_us * 7u + period_q8_us) / 8u;
            }
            edge_count++;
        }
    }
    last_edge_us = now_us;
}

static uint32_t clamp_rate(uint32_t hz) {
    if (hz < PGM_AUDIO_MIN_SAMPLE_RATE) {
        return PGM_AUDIO_MIN_SAMPLE_RATE;
    }
    if (hz > PGM_AUDIO_MAX_SAMPLE_RATE) {
        return PGM_AUDIO_MAX_SAMPLE_RATE;
    }
    return hz;
}

void rate_measure_init(uint32_t lrclk_gpio) {
    current_rate_hz = PGM_AUDIO_NOMINAL_SAMPLE_RATE;
    current_rate_valid = false;
    measured_gpio = lrclk_gpio;
    last_edge_us = 0;
    filtered_period_q8_us = 0;
    edge_count = 0;
    irq_enabled = false;

    gpio_init(measured_gpio);
    gpio_set_dir(measured_gpio, GPIO_IN);
    gpio_pull_down(measured_gpio);
    gpio_set_irq_enabled(measured_gpio, GPIO_IRQ_EDGE_RISE, false);
}

void rate_measure_enable(void) {
    if (irq_enabled) {
        return;
    }

    last_edge_us = 0;
    filtered_period_q8_us = 0;
    edge_count = 0;
    gpio_set_irq_enabled_with_callback(measured_gpio, GPIO_IRQ_EDGE_RISE, true, &rate_measure_gpio_irq);
    irq_enabled = true;
}

void rate_measure_task(void) {
    uint32_t snapshot_period_q8_us = filtered_period_q8_us;
    uint32_t snapshot_last_edge_us = last_edge_us;
    uint32_t snapshot_edge_count = edge_count;

    if (snapshot_last_edge_us == 0 || snapshot_edge_count < 4 || snapshot_period_q8_us == 0) {
        current_rate_valid = false;
        return;
    }

    uint32_t idle_us = time_us_32() - snapshot_last_edge_us;
    uint32_t filtered_period_us = snapshot_period_q8_us >> 8;
    if (filtered_period_us == 0 || idle_us > (filtered_period_us * 8u + 1000u)) {
        current_rate_valid = false;
        return;
    }

    uint32_t measured_hz = (1000000u << 8) / snapshot_period_q8_us;
    current_rate_hz = clamp_rate(measured_hz);
    current_rate_valid = true;
}

void rate_measure_set_mock_hz(uint32_t sample_rate_hz) {
    current_rate_hz = clamp_rate(sample_rate_hz);
    current_rate_valid = true;
}

uint32_t rate_measure_get_hz(void) {
    return current_rate_hz;
}

bool rate_measure_is_valid(void) {
    return current_rate_valid;
}
