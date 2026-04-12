# TODO

## Not yet implemented

- actual PIO/DMA capture from `CLK`, `LRCLK`, and `SI`
- runtime LRCLK/bit-clock measurement from GPIO edges
- exact backward-justified sample alignment
- host validation across macOS/Linux/Windows

## Planned next steps

1. Implement GPIO/PIO-based LRCLK and CLK observation.
2. Measure current sample rate from LRCLK continuously.
3. Implement PIO + DMA capture of 16-bit stereo frames.
4. Confirm exact LRCLK polarity and bit alignment against hardware.
5. Feed captured frames into the USB IN path instead of silence.
6. Tune packet sizing and clock reporting on host operating systems.
