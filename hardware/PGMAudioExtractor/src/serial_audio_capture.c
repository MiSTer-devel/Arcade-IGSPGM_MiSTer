#include "serial_audio_capture.h"

#include <string.h>

#include "capture_stream.h"
#include "hardware/dma.h"
#include "hardware/irq.h"
#include "hardware/pio.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include "pico/time.h"
#include "rate_measure.h"
#include "serial_audio_capture.pio.h"

#define SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK 256u
#define SERIAL_AUDIO_CAPTURE_DMA_BLOCK_COUNT 2u
#define SERIAL_AUDIO_CAPTURE_MAX_FRAMES_PER_BLOCK (SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK / 2u)

static serial_audio_capture_config_t capture_config;
static bool capture_running;

static PIO capture_pio = pio0;
static uint capture_sm;
static int capture_dma_chan = -1;
static uint8_t dma_active_block;
static volatile uint8_t dma_ready_mask;
static uint32_t dma_blocks[SERIAL_AUDIO_CAPTURE_DMA_BLOCK_COUNT][SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK];

static bool parser_synced;
static uint32_t parser_word_count;
static int16_t pending_left_sample;
static int16_t pending_right_sample;
static bool pending_left_valid;
static bool pending_right_valid;
static stereo_frame_t block_frames[SERIAL_AUDIO_CAPTURE_MAX_FRAMES_PER_BLOCK];
static uint32_t block_frame_count;
static uint64_t emitted_frame_index;
static uint32_t emitted_block_count;

static volatile uint32_t dropped_dma_blocks;
static volatile uint32_t dropped_audio_frames;
static volatile uint32_t processed_dma_blocks;
static volatile uint32_t channel_word_count;
static volatile uint32_t stereo_frame_count;
static volatile uint32_t nonzero_sample_count;
static volatile int16_t last_left_sample;
static volatile int16_t last_right_sample;

static bool serial_audio_capture_config_valid(void) {
    return capture_config.bits_per_sample == 16u &&
           capture_config.clk_gpio == (capture_config.si_gpio + 1u) &&
           capture_config.lrclk_gpio == (capture_config.si_gpio + 2u);
}

static inline int16_t sign_extend_sample(uint16_t sample) {
    return (int16_t)sample;
}

static void queue_audio_frame(int16_t left, int16_t right) {
    last_left_sample = left;
    last_right_sample = right;
    stereo_frame_count++;
    if (left != 0) {
        nonzero_sample_count++;
    }
    if (right != 0) {
        nonzero_sample_count++;
    }

    if (block_frame_count >= SERIAL_AUDIO_CAPTURE_MAX_FRAMES_PER_BLOCK) {
        dropped_audio_frames++;
        return;
    }

    block_frames[block_frame_count].left = left;
    block_frames[block_frame_count].right = right;
    block_frame_count++;
}

static void finalize_channel_sample(bool is_left, uint16_t sample) {
    if (!parser_synced) {
        parser_synced = true;
        return;
    }

    if (is_left) {
        pending_left_sample = sign_extend_sample(sample);
        pending_left_valid = true;
    } else {
        pending_right_sample = sign_extend_sample(sample);
        pending_right_valid = true;
    }

    if (pending_left_valid && pending_right_valid) {
        queue_audio_frame(pending_left_sample, pending_right_sample);
        pending_left_valid = false;
        pending_right_valid = false;
    }
}

static void process_channel_word(uint32_t word) {
    bool pushed_left = (word & 0x1u) != 0;
    bool is_left = capture_config.lrclk_low_is_left ? pushed_left : !pushed_left;
    uint16_t sample = (uint16_t)((word >> 1u) & 0xffffu);

    parser_word_count++;
    channel_word_count++;
    finalize_channel_sample(is_left, sample);
}

static uint32_t build_capture_flags(void) {
    uint32_t flags = 0;
    if (rate_measure_is_valid()) {
        flags |= PGM_CAPTURE_FLAG_RATE_VALID;
    }
    if (capture_running) {
        flags |= PGM_CAPTURE_FLAG_CAPTURE_RUNNING;
    }
    if (dropped_dma_blocks != 0) {
        flags |= PGM_CAPTURE_FLAG_DMA_DROP;
    }
    if (dropped_audio_frames != 0) {
        flags |= PGM_CAPTURE_FLAG_AUDIO_DROP;
    }
    if (!capture_stream_connected()) {
        flags |= PGM_CAPTURE_FLAG_NO_HOST;
    }
    if (capture_stream_get_dropped_packets() != 0) {
        flags |= PGM_CAPTURE_FLAG_QUEUE_DROP;
    }
    if (capture_stream_get_mode() != PGM_CAPTURE_STREAM_MODE_CONTINUOUS) {
        flags |= PGM_CAPTURE_FLAG_TRIGGERED_MODE;
    }
    return flags;
}

static void process_dma_block(const uint32_t *block) {
    block_frame_count = 0;
    for (uint32_t i = 0; i < SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK; ++i) {
        process_channel_word(block[i]);
    }

    if (block_frame_count == 0u) {
        return;
    }

    uint64_t frame_start = emitted_frame_index;
    uint64_t t_us = time_us_64();
    uint32_t raw_lrclk_hz = rate_measure_get_raw_hz();
    uint32_t flags = build_capture_flags();

    emitted_frame_index += block_frame_count;
    emitted_block_count++;

    capture_stream_submit_audio(frame_start, t_us, raw_lrclk_hz, flags, block_frames, block_frame_count);
}

static void serial_audio_capture_dma_irq_handler(void) {
    if (capture_dma_chan < 0) {
        return;
    }

    uint32_t mask = 1u << (uint32_t)capture_dma_chan;
    if ((dma_hw->ints0 & mask) == 0) {
        return;
    }

    dma_hw->ints0 = mask;

    uint8_t completed_block = dma_active_block;
    dma_ready_mask |= (uint8_t)(1u << completed_block);

    dma_active_block ^= 1u;
    if ((dma_ready_mask & (1u << dma_active_block)) != 0) {
        dropped_dma_blocks++;
    }

    dma_channel_set_write_addr(capture_dma_chan, dma_blocks[dma_active_block], false);
    dma_channel_set_trans_count(capture_dma_chan, SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK, true);
}

static bool serial_audio_capture_take_ready_block(uint8_t *block_index) {
    uint32_t irq_state = save_and_disable_interrupts();
    uint8_t ready_mask = dma_ready_mask;
    if (ready_mask == 0) {
        restore_interrupts(irq_state);
        return false;
    }

    *block_index = (ready_mask & 0x1u) ? 0u : 1u;
    dma_ready_mask &= (uint8_t)~(1u << *block_index);
    restore_interrupts(irq_state);
    return true;
}

static void serial_audio_capture_start_dma(void) {
    dma_channel_config dma_config = dma_channel_get_default_config((uint)capture_dma_chan);
    channel_config_set_transfer_data_size(&dma_config, DMA_SIZE_32);
    channel_config_set_read_increment(&dma_config, false);
    channel_config_set_write_increment(&dma_config, true);
    channel_config_set_dreq(&dma_config, pio_get_dreq(capture_pio, capture_sm, false));

    dma_channel_configure(capture_dma_chan,
                          &dma_config,
                          dma_blocks[0],
                          &capture_pio->rxf[capture_sm],
                          SERIAL_AUDIO_CAPTURE_DMA_WORDS_PER_BLOCK,
                          false);

    dma_channel_acknowledge_irq0((uint)capture_dma_chan);
    dma_channel_set_irq0_enabled((uint)capture_dma_chan, true);
    irq_set_exclusive_handler(DMA_IRQ_0, serial_audio_capture_dma_irq_handler);
    irq_set_enabled(DMA_IRQ_0, true);

    dma_active_block = 0;
    dma_ready_mask = 0;
    dma_channel_start((uint)capture_dma_chan);
}

void serial_audio_capture_init(const serial_audio_capture_config_t *config) {
    capture_config = *config;
    capture_running = false;
    parser_synced = false;
    parser_word_count = 0;
    pending_left_sample = 0;
    pending_right_sample = 0;
    pending_left_valid = false;
    pending_right_valid = false;
    block_frame_count = 0;
    emitted_frame_index = 0;
    emitted_block_count = 0;
    dropped_dma_blocks = 0;
    dropped_audio_frames = 0;
    processed_dma_blocks = 0;
    channel_word_count = 0;
    stereo_frame_count = 0;
    nonzero_sample_count = 0;
    last_left_sample = 0;
    last_right_sample = 0;
    capture_dma_chan = -1;

    if (!serial_audio_capture_config_valid()) {
        return;
    }

    gpio_init(capture_config.clk_gpio);
    gpio_set_dir(capture_config.clk_gpio, GPIO_IN);
    gpio_disable_pulls(capture_config.clk_gpio);
    gpio_init(capture_config.lrclk_gpio);
    gpio_set_dir(capture_config.lrclk_gpio, GPIO_IN);
    gpio_disable_pulls(capture_config.lrclk_gpio);
    gpio_init(capture_config.si_gpio);
    gpio_set_dir(capture_config.si_gpio, GPIO_IN);
    gpio_disable_pulls(capture_config.si_gpio);
}

void serial_audio_capture_enable(void) {
    if (capture_running || !serial_audio_capture_config_valid()) {
        return;
    }

    capture_sm = pio_claim_unused_sm(capture_pio, true);
    uint capture_offset = pio_add_program(capture_pio, &serial_audio_capture_lr_program);

    pio_gpio_init(capture_pio, capture_config.si_gpio);
    pio_gpio_init(capture_pio, capture_config.clk_gpio);
    pio_gpio_init(capture_pio, capture_config.lrclk_gpio);

    pio_sm_config sm_config = serial_audio_capture_lr_program_get_default_config(capture_offset);
    sm_config_set_in_pins(&sm_config, capture_config.si_gpio);
    sm_config_set_in_shift(&sm_config, false, false, 0);
    sm_config_set_fifo_join(&sm_config, PIO_FIFO_JOIN_RX);
    sm_config_set_clkdiv(&sm_config, 1.0f);
    sm_config_set_in_pin_count(&sm_config, 2);
    sm_config_set_jmp_pin(&sm_config, capture_config.lrclk_gpio);

    uint entry_offset = capture_offset;
    pio_sm_init(capture_pio, capture_sm, entry_offset, &sm_config);
    pio_sm_set_consecutive_pindirs(capture_pio, capture_sm, capture_config.si_gpio, 2, false);
    pio_sm_set_consecutive_pindirs(capture_pio, capture_sm, capture_config.lrclk_gpio, 1, false);
    pio_sm_set_enabled(capture_pio, capture_sm, true);

    capture_dma_chan = dma_claim_unused_channel(true);
    serial_audio_capture_start_dma();
    capture_running = true;
}

void serial_audio_capture_task(void) {
    uint8_t block_index;
    if (serial_audio_capture_take_ready_block(&block_index)) {
        process_dma_block(dma_blocks[block_index]);
        processed_dma_blocks++;
    }
}

bool serial_audio_capture_is_running(void) {
    return capture_running;
}

uint32_t serial_audio_capture_get_processed_dma_blocks(void) {
    return processed_dma_blocks;
}

uint32_t serial_audio_capture_get_ready_mask(void) {
    return dma_ready_mask;
}

uint32_t serial_audio_capture_get_dropped_dma_blocks(void) {
    return dropped_dma_blocks;
}

uint32_t serial_audio_capture_get_dropped_audio_frames(void) {
    return dropped_audio_frames;
}

uint32_t serial_audio_capture_get_channel_word_count(void) {
    return channel_word_count;
}

uint32_t serial_audio_capture_get_stereo_frame_count(void) {
    return stereo_frame_count;
}

uint32_t serial_audio_capture_get_nonzero_sample_count(void) {
    return nonzero_sample_count;
}

uint64_t serial_audio_capture_get_emitted_frame_index(void) {
    return emitted_frame_index;
}

uint32_t serial_audio_capture_get_emitted_block_count(void) {
    return emitted_block_count;
}

int16_t serial_audio_capture_get_last_left_sample(void) {
    return last_left_sample;
}

int16_t serial_audio_capture_get_last_right_sample(void) {
    return last_right_sample;
}
