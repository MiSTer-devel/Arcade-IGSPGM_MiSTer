# PGMAudioExtractor

Firmware scaffold for an RP2350-based Pico 2 board that captures external stereo serial audio and exposes it to a host PC as a USB Audio Class 2.0 recording device.

## Current scaffold status

This repository currently includes:

- `pico-sdk` as a git submodule
- CMake-based Pico SDK project setup
- TinyUSB UAC2 stereo capture descriptors
- audio clock/rate reporting scaffold for a variable input sample rate
- ring buffer for stereo 16-bit frames
- placeholder serial-audio capture module and PIO source file
- USB streaming path that currently emits silence when no captured frames are available

It does **not** yet implement:

See [TODO.md](TODO.md) for the current implementation gaps and planned next steps.

## Target audio path

Input format assumptions so far:

- externally clocked serial audio
- signals: `CLK`, `LRCLK`, `SI`
- stereo
- signed 16-bit PCM
- 2's complement
- MSB first
- backward-justified / I2S-like timing
- sample rate can vary dynamically from about `33.8 kHz` to `44.1 kHz`

USB target:

- USB Audio Class 2.0
- stereo capture device
- 16-bit PCM
- current sample rate reported dynamically from the measured input clock

## Build

Simplest workflow:

```sh
make
```

This will configure CMake, build the firmware, and produce the UF2 in `build/`.

Useful targets:

```sh
make                 # build UF2
make build           # configure + build
make info            # reboot to BOOTSEL and query device info
make load            # build, reboot to BOOTSEL, load UF2
make bootsel         # reboot device into BOOTSEL mode
make app             # reboot device into application mode
make monitor         # open a serial monitor using screen
make clean           # remove build directory
```

Note: `picotool load` returns the device to application mode automatically after a successful load.

Defaults can be overridden:

```sh
make PICO_BOARD=pico2
make UF2=build/pgm_audio_extractor.uf2 load
make PORT=/dev/cu.usbmodem1234561 monitor
```

`make monitor` auto-detects one of:

- `/dev/cu.usbmodem*`
- `/dev/tty.usbmodem*`
- `/dev/cu.usbserial*`
- `/dev/tty.usbserial*`
- `/dev/tty.debug-console`
- `/dev/cu.debug-console`

and uses `screen` at `115200` baud by default. Override with `PORT=` and `MONITOR_BAUD=` if needed. On this machine, the working CDC console appeared as `/dev/tty.usbmodem*`.

Outputs are generated in `build/`, including UF2 and ELF artifacts.

## File layout

- `CMakeLists.txt` - project build setup
- `Makefile` - build and `picotool` helper targets
- `src/main.c` - top-level init and main loop
- `src/tusb_config.h` - TinyUSB configuration
- `src/usb_descriptors.[ch]` - USB device and configuration descriptors
- `src/usb_audio.[ch]` - UAC2 control and streaming callbacks
- `src/serial_audio_capture.[ch]` - capture-side scaffold
- `src/serial_audio_capture.pio` - placeholder PIO program source
- `src/rate_measure.[ch]` - dynamic sample-rate tracking scaffold
- `src/ring_buffer.[ch]` - stereo PCM frame buffer
