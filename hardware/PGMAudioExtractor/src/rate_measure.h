#ifndef RATE_MEASURE_H
#define RATE_MEASURE_H

#include <stdbool.h>
#include <stdint.h>

void rate_measure_init(uint32_t lrclk_gpio);
void rate_measure_enable(void);
void rate_measure_task(void);
void rate_measure_set_mock_hz(uint32_t sample_rate_hz);
uint32_t rate_measure_get_hz(void);
bool rate_measure_is_valid(void);

#endif
