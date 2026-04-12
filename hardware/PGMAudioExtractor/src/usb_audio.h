#ifndef USB_AUDIO_H
#define USB_AUDIO_H

#include <stdint.h>

#include "ring_buffer.h"

void usb_audio_init(void);
void usb_audio_task(void);
uint32_t usb_audio_get_current_sample_rate(void);
stereo_ring_buffer_t *usb_audio_get_capture_ring_buffer(void);

#endif
