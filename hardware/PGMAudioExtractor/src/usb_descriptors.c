#include <string.h>

#include "bsp/board_api.h"
#include "hardware/watchdog.h"
#include "pico/bootrom.h"
#include "tusb.h"
#include "usb_descriptors.h"

#define _PID_MAP(itf, n) ((CFG_TUD_##itf) << (n))
#define USB_PID (0x4000 | _PID_MAP(CDC, 0) | _PID_MAP(MSC, 1) | _PID_MAP(HID, 2) | _PID_MAP(MIDI, 3) | _PID_MAP(AUDIO, 4) | _PID_MAP(VENDOR, 5))

tusb_desc_device_t const desc_device = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = 0x2E8A,
    .idProduct = 0x0009,
    .bcdDevice = 0x0100,
    .iManufacturer = 0x01,
    .iProduct = 0x02,
    .iSerialNumber = 0x03,
    .bNumConfigurations = 0x01,
};

uint8_t const *tud_descriptor_device_cb(void) {
    return (uint8_t const *)&desc_device;
}

#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + CFG_TUD_AUDIO * TUD_AUDIO_MIC_STEREO_DESC_LEN + CFG_TUD_CDC * TUD_CDC_DESC_LEN + TUD_RPI_RESET_DESC_LEN)

#if TU_CHECK_MCU(OPT_MCU_LPC175X_6X, OPT_MCU_LPC177X_8X, OPT_MCU_LPC40XX)
#define EPNUM_AUDIO 0x03
#define EPNUM_CDC_NOTIF 0x84
#define EPNUM_CDC_OUT 0x05
#define EPNUM_CDC_IN 0x85
#elif TU_CHECK_MCU(OPT_MCU_NRF5X)
#define EPNUM_AUDIO 0x08
#define EPNUM_CDC_NOTIF 0x81
#define EPNUM_CDC_OUT 0x02
#define EPNUM_CDC_IN 0x82
#else
#define EPNUM_AUDIO 0x01
#define EPNUM_CDC_NOTIF 0x83
#define EPNUM_CDC_OUT 0x04
#define EPNUM_CDC_IN 0x84
#endif

uint8_t const desc_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0x00, 100),
    TUD_AUDIO_MIC_STEREO_DESCRIPTOR(ITF_NUM_AUDIO_CONTROL, 0x04, 0x80 | EPNUM_AUDIO, CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX),
    TUD_CDC_DESCRIPTOR(ITF_NUM_CDC, 0x05, EPNUM_CDC_NOTIF, 8, EPNUM_CDC_OUT, EPNUM_CDC_IN, 64),
    TUD_RPI_RESET_DESCRIPTOR(ITF_NUM_RESET, 0x06),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
    (void)index;
    return desc_configuration;
}

enum {
    STRID_LANGID = 0,
    STRID_MANUFACTURER,
    STRID_PRODUCT,
    STRID_SERIAL,
    STRID_AUDIO,
    STRID_CDC,
    STRID_RESET,
};

static char const *const string_desc_arr[] = {
    (const char[]){0x09, 0x04},
    "wickerwaka",
    "PGM Audio Extractor",
    NULL,
    "USB Audio Capture",
    "PGM Debug Console",
    "Reset",
};

static uint16_t desc_str[32 + 1];

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
    (void)langid;
    size_t chr_count;

    switch (index) {
        case STRID_LANGID:
            memcpy(&desc_str[1], string_desc_arr[0], 2);
            chr_count = 1;
            break;
        case STRID_SERIAL:
            chr_count = board_usb_get_serial(desc_str + 1, 32);
            break;
        default: {
            if (index >= (sizeof(string_desc_arr) / sizeof(string_desc_arr[0]))) {
                return NULL;
            }
            const char *str = string_desc_arr[index];
            chr_count = strlen(str);
            size_t max_count = (sizeof(desc_str) / sizeof(desc_str[0])) - 1;
            if (chr_count > max_count) {
                chr_count = max_count;
            }
            for (size_t i = 0; i < chr_count; ++i) {
                desc_str[1 + i] = str[i];
            }
            break;
        }
    }

    desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * chr_count + 2));
    return desc_str;
}
