#include "tusb.h"
#include "device/usbd_pvt.h"
#include "hardware/watchdog.h"
#include "pico/bootrom.h"
#include "pico/stdio_usb/reset_interface.h"
#include "usb_descriptors.h"

static uint8_t reset_itf_num;

static void resetd_init(void) {
    reset_itf_num = 0xff;
}

static void resetd_reset(uint8_t rhport) {
    (void)rhport;
    reset_itf_num = 0xff;
}

static uint16_t resetd_open(uint8_t rhport, tusb_desc_interface_t const *itf_desc, uint16_t max_len) {
    (void)rhport;

    TU_VERIFY(TUSB_CLASS_VENDOR_SPECIFIC == itf_desc->bInterfaceClass &&
              RESET_INTERFACE_SUBCLASS == itf_desc->bInterfaceSubClass &&
              RESET_INTERFACE_PROTOCOL == itf_desc->bInterfaceProtocol, 0);

    uint16_t const drv_len = sizeof(tusb_desc_interface_t);
    TU_VERIFY(max_len >= drv_len, 0);

    reset_itf_num = itf_desc->bInterfaceNumber;
    return drv_len;
}

static bool resetd_control_xfer_cb(uint8_t rhport, uint8_t stage, tusb_control_request_t const *request) {
    (void)rhport;

    if (stage != CONTROL_STAGE_SETUP) {
        return true;
    }

    if (request->wIndex != reset_itf_num) {
        return false;
    }

    if (request->bRequest == RESET_REQUEST_BOOTSEL) {
        int gpio = -1;
        bool active_low = false;
        if (request->wValue & 0x100) {
            gpio = request->wValue >> 9u;
        }
        active_low = (request->wValue & 0x200) != 0;
        rom_reset_usb_boot_extra(gpio, request->wValue & 0x7f, active_low);
    }

    if (request->bRequest == RESET_REQUEST_FLASH) {
        watchdog_reboot(0, 0, 100);
        return true;
    }

    return false;
}

static bool resetd_xfer_cb(uint8_t rhport, uint8_t ep_addr, xfer_result_t result, uint32_t xferred_bytes) {
    (void)rhport;
    (void)ep_addr;
    (void)result;
    (void)xferred_bytes;
    return true;
}

static usbd_class_driver_t const resetd_driver = {
#if CFG_TUSB_DEBUG >= 2
    .name = "RESET",
#endif
    .init = resetd_init,
    .reset = resetd_reset,
    .open = resetd_open,
    .control_xfer_cb = resetd_control_xfer_cb,
    .xfer_cb = resetd_xfer_cb,
    .sof = NULL,
};

usbd_class_driver_t const *usbd_app_driver_get_cb(uint8_t *driver_count) {
    *driver_count = 1;
    return &resetd_driver;
}
