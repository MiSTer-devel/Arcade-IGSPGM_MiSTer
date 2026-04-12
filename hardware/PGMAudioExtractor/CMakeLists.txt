cmake_minimum_required(VERSION 3.19)

set(PICO_BOARD pico2 CACHE STRING "Target board")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(${CMAKE_CURRENT_LIST_DIR}/pico-sdk/pico_sdk_init.cmake)

project(PGMAudioExtractor C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(pgm_audio_extractor
    src/main.c
    src/reset_interface_app.c
    src/usb_audio.c
    src/usb_descriptors.c
    src/serial_audio_capture.c
    src/rate_measure.c
    src/ring_buffer.c
)

pico_generate_pio_header(pgm_audio_extractor
    ${CMAKE_CURRENT_LIST_DIR}/src/serial_audio_capture.pio
)

target_include_directories(pgm_audio_extractor PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
)

target_link_libraries(pgm_audio_extractor PRIVATE
    pico_stdlib
    tinyusb_device
    tinyusb_board
    hardware_pio
    hardware_dma
    hardware_gpio
    hardware_irq
    hardware_timer
    hardware_clocks
    hardware_pwm
    hardware_sync
)

target_compile_definitions(pgm_audio_extractor PRIVATE
    PGM_AUDIO_MIN_SAMPLE_RATE=33800
    PGM_AUDIO_MAX_SAMPLE_RATE=44100
    PGM_AUDIO_NOMINAL_SAMPLE_RATE=44100
    PICO_STDIO_USB_ENABLE_RESET_VIA_VENDOR_INTERFACE=0
    PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=0
)

pico_enable_stdio_uart(pgm_audio_extractor 0)
pico_enable_stdio_usb(pgm_audio_extractor 1)

pico_add_extra_outputs(pgm_audio_extractor)
