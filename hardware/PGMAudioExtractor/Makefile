SHELL := /bin/bash

PICO_BOARD ?= pico2
BUILD_DIR ?= build
TARGET ?= pgm_audio_extractor
UF2 ?= $(BUILD_DIR)/$(TARGET).uf2
CMAKE ?= cmake
PICOTOOL ?= picotool
MONITOR_BAUD ?= 115200
PORT ?=

AUTO_PORT = $$(ls /dev/tty.usbmodem* /dev/cu.usbmodem* /dev/tty.usbserial* /dev/cu.usbserial* /dev/tty.debug-console /dev/cu.debug-console 2>/dev/null | head -n 1)
MONITOR_PORT = $${PORT:-$(AUTO_PORT)}

.PHONY: all configure build uf2 bootsel app info load monitor clean

all: uf2

configure:
	$(CMAKE) -S . -B $(BUILD_DIR) -DPICO_BOARD=$(PICO_BOARD)
	@ln -sfn $(BUILD_DIR)/compile_commands.json compile_commands.json

build: configure
	$(CMAKE) --build $(BUILD_DIR)

uf2: build
	@test -f $(UF2)
	@echo "Built $(UF2)"

bootsel:
	@$(PICOTOOL) reboot -u -F || { echo "BOOTSEL PLZ?!"; exit 1; }
	@sleep 2

app:
	$(PICOTOOL) reboot -a -F

info:
	@$(PICOTOOL) -f info || { echo "BOOTSEL PLZ?!"; exit 1; }

load: uf2
	@$(PICOTOOL) load -f $(UF2) || { echo "BOOTSEL PLZ?!"; exit 1; }
	@${PICOTOOL} reboot -a -F

monitor:
	@port='$(PORT)'; \
	if [[ -z "$$port" ]]; then \
		port=$$(ls /dev/tty.usbmodem* /dev/cu.usbmodem* /dev/tty.usbserial* /dev/cu.usbserial* /dev/tty.debug-console /dev/cu.debug-console 2>/dev/null | head -n 1); \
	fi; \
	if [[ -z "$$port" ]]; then \
		echo "No serial port found. Set PORT=/dev/cu.<device>"; \
		exit 1; \
	fi; \
	if ! command -v screen >/dev/null 2>&1; then \
		echo "screen not found"; \
		exit 1; \
	fi; \
	printf 'Opening %s at %s baud\n' "$$port" "$(MONITOR_BAUD)"; \
	exec screen $$port $(MONITOR_BAUD)

clean:
	@rm -rf $(BUILD_DIR)
