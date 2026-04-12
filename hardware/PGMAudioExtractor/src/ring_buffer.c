#include "ring_buffer.h"

void stereo_ring_buffer_init(stereo_ring_buffer_t *rb, stereo_frame_t *storage, size_t capacity) {
    rb->frames = storage;
    rb->capacity = capacity;
    rb->read_index = 0;
    rb->write_index = 0;
    rb->count = 0;
}

size_t stereo_ring_buffer_write(stereo_ring_buffer_t *rb, const stereo_frame_t *frames, size_t frame_count) {
    size_t written = 0;
    while (written < frame_count && rb->count < rb->capacity) {
        rb->frames[rb->write_index] = frames[written++];
        rb->write_index = (rb->write_index + 1u) % rb->capacity;
        rb->count++;
    }
    return written;
}

size_t stereo_ring_buffer_read(stereo_ring_buffer_t *rb, stereo_frame_t *frames, size_t frame_count) {
    size_t read = 0;
    while (read < frame_count && rb->count > 0) {
        frames[read++] = rb->frames[rb->read_index];
        rb->read_index = (rb->read_index + 1u) % rb->capacity;
        rb->count--;
    }
    return read;
}

size_t stereo_ring_buffer_level(const stereo_ring_buffer_t *rb) {
    return rb->count;
}

size_t stereo_ring_buffer_space(const stereo_ring_buffer_t *rb) {
    return rb->capacity - rb->count;
}

void stereo_ring_buffer_clear(stereo_ring_buffer_t *rb) {
    rb->read_index = 0;
    rb->write_index = 0;
    rb->count = 0;
}
