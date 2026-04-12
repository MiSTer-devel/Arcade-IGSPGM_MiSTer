#include "usb_audio.h"

#include <string.h>

#include "pico/stdlib.h"
#include "rate_measure.h"
#include "ring_buffer.h"
#include "tusb.h"
#include "usb_descriptors.h"

#ifndef PGM_AUDIO_MIN_SAMPLE_RATE
#define PGM_AUDIO_MIN_SAMPLE_RATE 33800u
#endif

#ifndef PGM_AUDIO_MAX_SAMPLE_RATE
#define PGM_AUDIO_MAX_SAMPLE_RATE 44100u
#endif

#define AUDIO_STREAMING_ALT_OFF 0u
#define AUDIO_STREAMING_ALT_PCM16 1u
#define USB_FRAME_RATE_HZ (TUD_OPT_HIGH_SPEED ? 8000u : 1000u)
#define CAPTURE_RING_FRAMES 2048u
#define TEST_TONE_HZ 440u

static const int16_t sine_lut[256] = {
         0,    736,   1472,   2207,   2941,   3672,   4402,   5129,
      5853,   6573,   7289,   8001,   8709,   9410,  10107,  10797,
     11481,  12157,  12827,  13488,  14142,  14787,  15423,  16050,
     16667,  17274,  17871,  18457,  19032,  19595,  20147,  20686,
     21213,  21727,  22229,  22716,  23190,  23650,  24096,  24528,
     24944,  25346,  25732,  26103,  26458,  26797,  27120,  27426,
     27716,  27990,  28246,  28486,  28708,  28913,  29101,  29271,
     29424,  29558,  29675,  29774,  29856,  29919,  29964,  29991,
     30000,  29991,  29964,  29919,  29856,  29774,  29675,  29558,
     29424,  29271,  29101,  28913,  28708,  28486,  28246,  27990,
     27716,  27426,  27120,  26797,  26458,  26103,  25732,  25346,
     24944,  24528,  24096,  23650,  23190,  22716,  22229,  21727,
     21213,  20686,  20147,  19595,  19032,  18457,  17871,  17274,
     16667,  16050,  15423,  14787,  14142,  13488,  12827,  12157,
     11481,  10797,  10107,   9410,   8709,   8001,   7289,   6573,
      5853,   5129,   4402,   3672,   2941,   2207,   1472,    736,
         0,   -736,  -1472,  -2207,  -2941,  -3672,  -4402,  -5129,
     -5853,  -6573,  -7289,  -8001,  -8709,  -9410, -10107, -10797,
    -11481, -12157, -12827, -13488, -14142, -14787, -15423, -16050,
    -16667, -17274, -17871, -18457, -19032, -19595, -20147, -20686,
    -21213, -21727, -22229, -22716, -23190, -23650, -24096, -24528,
    -24944, -25346, -25732, -26103, -26458, -26797, -27120, -27426,
    -27716, -27990, -28246, -28486, -28708, -28913, -29101, -29271,
    -29424, -29558, -29675, -29774, -29856, -29919, -29964, -29991,
    -30000, -29991, -29964, -29919, -29856, -29774, -29675, -29558,
    -29424, -29271, -29101, -28913, -28708, -28486, -28246, -27990,
    -27716, -27426, -27120, -26797, -26458, -26103, -25732, -25346,
    -24944, -24528, -24096, -23650, -23190, -22716, -22229, -21727,
    -21213, -20686, -20147, -19595, -19032, -18457, -17871, -17274,
    -16667, -16050, -15423, -14787, -14142, -13488, -12827, -12157,
    -11481, -10797, -10107,  -9410,  -8709,  -8001,  -7289,  -6573,
     -5853,  -5129,  -4402,  -3672,  -2941,  -2207,  -1472,   -736,
};

static bool mute[CFG_TUD_AUDIO_FUNC_1_N_CHANNELS_TX + 1];
static uint8_t clock_valid;
static uint8_t current_alt_setting;
static uint32_t packet_frame_accumulator;
static uint32_t sine_phase;
static stereo_frame_t capture_storage[CAPTURE_RING_FRAMES];
static stereo_ring_buffer_t capture_rb;
static stereo_frame_t tx_packet[CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX / sizeof(stereo_frame_t)];

static uint32_t clamp_sample_rate(uint32_t hz) {
    if (hz < PGM_AUDIO_MIN_SAMPLE_RATE) {
        return PGM_AUDIO_MIN_SAMPLE_RATE;
    }
    if (hz > PGM_AUDIO_MAX_SAMPLE_RATE) {
        return PGM_AUDIO_MAX_SAMPLE_RATE;
    }
    return hz;
}

static void generate_sine_frames(stereo_frame_t *frames, uint16_t frame_count, uint32_t sample_rate_hz) {
    if (sample_rate_hz == 0) {
        sample_rate_hz = PGM_AUDIO_MAX_SAMPLE_RATE;
    }

    uint32_t phase_step = (uint32_t)(((uint64_t)TEST_TONE_HZ << 32) / sample_rate_hz);
    for (uint16_t i = 0; i < frame_count; ++i) {
        int16_t sample = sine_lut[sine_phase >> 24];
        frames[i].left = sample;
        frames[i].right = sample;
        sine_phase += phase_step;
    }
}

static uint16_t build_tx_packet(stereo_frame_t *frames, uint16_t max_frames) {
    uint32_t current_rate_hz = clamp_sample_rate(rate_measure_get_hz());
    packet_frame_accumulator += current_rate_hz;
    uint16_t requested_frames = (uint16_t)(packet_frame_accumulator / USB_FRAME_RATE_HZ);
    packet_frame_accumulator %= USB_FRAME_RATE_HZ;

    if (requested_frames > max_frames) {
        requested_frames = max_frames;
    }

    uint16_t read_frames = (uint16_t)stereo_ring_buffer_read(&capture_rb, frames, requested_frames);
    if (read_frames < requested_frames) {
        generate_sine_frames(&frames[read_frames], (uint16_t)(requested_frames - read_frames), current_rate_hz);
    }

    return (uint16_t)(requested_frames * sizeof(stereo_frame_t));
}

void usb_audio_init(void) {
    memset(mute, 0, sizeof(mute));
    clock_valid = 1;
    current_alt_setting = AUDIO_STREAMING_ALT_OFF;
    packet_frame_accumulator = 0;
    sine_phase = 0;
    stereo_ring_buffer_init(&capture_rb, capture_storage, CAPTURE_RING_FRAMES);
}

void usb_audio_task(void) {
    clock_valid = rate_measure_is_valid() ? 1u : 0u;
}

uint32_t usb_audio_get_current_sample_rate(void) {
    return clamp_sample_rate(rate_measure_get_hz());
}

stereo_ring_buffer_t *usb_audio_get_capture_ring_buffer(void) {
    return &capture_rb;
}

bool tud_audio_set_itf_cb(uint8_t rhport, tusb_control_request_t const *p_request) {
    (void)rhport;
    current_alt_setting = tu_u16_low(tu_le16toh(p_request->wValue));
    if (current_alt_setting == AUDIO_STREAMING_ALT_OFF) {
        packet_frame_accumulator = 0;
        sine_phase = 0;
        stereo_ring_buffer_clear(&capture_rb);
    }
    return true;
}

bool tud_audio_set_itf_close_EP_cb(uint8_t rhport, tusb_control_request_t const *p_request) {
    (void)rhport;
    (void)p_request;
    current_alt_setting = AUDIO_STREAMING_ALT_OFF;
    packet_frame_accumulator = 0;
    sine_phase = 0;
    stereo_ring_buffer_clear(&capture_rb);
    return true;
}

bool tud_audio_set_req_ep_cb(uint8_t rhport, tusb_control_request_t const *p_request, uint8_t *pBuff) {
    (void)rhport;
    (void)p_request;
    (void)pBuff;
    return false;
}

bool tud_audio_set_req_itf_cb(uint8_t rhport, tusb_control_request_t const *p_request, uint8_t *pBuff) {
    (void)rhport;
    (void)p_request;
    (void)pBuff;
    return false;
}

bool tud_audio_set_req_entity_cb(uint8_t rhport, tusb_control_request_t const *p_request, uint8_t *pBuff) {
    uint8_t channel_num = TU_U16_LOW(p_request->wValue);
    uint8_t ctrl_sel = TU_U16_HIGH(p_request->wValue);
    uint8_t entity_id = TU_U16_HIGH(p_request->wIndex);

    if (entity_id == UAC2_ENTITY_FEATURE_UNIT && p_request->bRequest == AUDIO_CS_REQ_CUR && ctrl_sel == AUDIO_FU_CTRL_MUTE) {
        TU_VERIFY(p_request->wLength == sizeof(audio_control_cur_1_t));
        mute[channel_num] = ((audio_control_cur_1_t *)pBuff)->bCur;
        return true;
    }

    (void)rhport;
    return false;
}

bool tud_audio_get_req_ep_cb(uint8_t rhport, tusb_control_request_t const *p_request) {
    (void)rhport;
    (void)p_request;
    return false;
}

bool tud_audio_get_req_itf_cb(uint8_t rhport, tusb_control_request_t const *p_request) {
    (void)rhport;
    (void)p_request;
    return false;
}

bool tud_audio_get_req_entity_cb(uint8_t rhport, tusb_control_request_t const *p_request) {
    uint8_t channel_num = TU_U16_LOW(p_request->wValue);
    uint8_t ctrl_sel = TU_U16_HIGH(p_request->wValue);
    uint8_t entity_id = TU_U16_HIGH(p_request->wIndex);

    if (entity_id == UAC2_ENTITY_INPUT_TERMINAL && ctrl_sel == AUDIO_TE_CTRL_CONNECTOR) {
        audio_desc_channel_cluster_t ret = {
            .bNrChannels = 2,
            .bmChannelConfig = 0,
            .iChannelNames = 0,
        };
        return tud_audio_buffer_and_schedule_control_xfer(rhport, p_request, &ret, sizeof(ret));
    }

    if (entity_id == UAC2_ENTITY_FEATURE_UNIT && ctrl_sel == AUDIO_FU_CTRL_MUTE && p_request->bRequest == AUDIO_CS_REQ_CUR) {
        return tud_control_xfer(rhport, p_request, &mute[channel_num], sizeof(mute[channel_num]));
    }

    if (entity_id == UAC2_ENTITY_CLOCK) {
        switch (ctrl_sel) {
            case AUDIO_CS_CTRL_SAM_FREQ:
                if (p_request->bRequest == AUDIO_CS_REQ_CUR) {
                    uint32_t current_rate = usb_audio_get_current_sample_rate();
                    return tud_control_xfer(rhport, p_request, &current_rate, sizeof(current_rate));
                }
                if (p_request->bRequest == AUDIO_CS_REQ_RANGE) {
                    audio_control_range_4_n_t(1) range = {
                        .wNumSubRanges = tu_htole16(1),
                    };
                    range.subrange[0].bMin = PGM_AUDIO_MIN_SAMPLE_RATE;
                    range.subrange[0].bMax = PGM_AUDIO_MAX_SAMPLE_RATE;
                    range.subrange[0].bRes = 1;
                    return tud_audio_buffer_and_schedule_control_xfer(rhport, p_request, &range, sizeof(range));
                }
                return false;
            case AUDIO_CS_CTRL_CLK_VALID:
                return tud_control_xfer(rhport, p_request, &clock_valid, sizeof(clock_valid));
            default:
                return false;
        }
    }

    return false;
}

bool tud_audio_tx_done_pre_load_cb(uint8_t rhport, uint8_t itf, uint8_t ep_in, uint8_t cur_alt_setting) {
    (void)rhport;
    (void)itf;
    (void)ep_in;

    if (cur_alt_setting != AUDIO_STREAMING_ALT_PCM16 || current_alt_setting != AUDIO_STREAMING_ALT_PCM16) {
        return true;
    }

    uint16_t bytes = build_tx_packet(tx_packet, TU_ARRAY_SIZE(tx_packet));
    tud_audio_write((uint8_t *)tx_packet, bytes);
    return true;
}

bool tud_audio_tx_done_post_load_cb(uint8_t rhport, uint16_t n_bytes_copied, uint8_t itf, uint8_t ep_in, uint8_t cur_alt_setting) {
    (void)rhport;
    (void)n_bytes_copied;
    (void)itf;
    (void)ep_in;
    (void)cur_alt_setting;
    return true;
}
