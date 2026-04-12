#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int16_t left;
    int16_t right;
} stereo_frame_t;

typedef struct {
    stereo_frame_t *frames;
    size_t capacity;
    volatile size_t read_index;
    volatile size_t write_index;
    volatile size_t count;
} stereo_ring_buffer_t;

void stereo_ring_buffer_init(stereo_ring_buffer_t *rb, stereo_frame_t *storage, size_t capacity);
size_t stereo_ring_buffer_write(stereo_ring_buffer_t *rb, const stereo_frame_t *frames, size_t frame_count);
size_t stereo_ring_buffer_read(stereo_ring_buffer_t *rb, stereo_frame_t *frames, size_t frame_count);
size_t stereo_ring_buffer_level(const stereo_ring_buffer_t *rb);
size_t stereo_ring_buffer_space(const stereo_ring_buffer_t *rb);
void stereo_ring_buffer_clear(stereo_ring_buffer_t *rb);

#endif
