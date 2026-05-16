CC = m68k-elf-gcc
OBJCOPY = m68k-elf-objcopy
OBJDUMP = m68k-elf-objdump
MAME = ../util/pgm_mame
PYTHON = uv run
VASM = ../util/vasmz80_oldstyle
MISTER_HOSTNAME=mister-dev

TARGET = pgm_test

SRCS =  init.c main.c util.c page.c gui.c igs023.c
SRCS += interrupts_default.c comms.c tilemap.c input.c color.c printf/printf.c

ifeq ($(strip $(PAGE)),)
#SRCS += pages/system_basics.c
#SRCS += pages/vram_test.c
#SRCS += pages/gui_test.c
#SRCS += pages/irq4_test.c
SRCS += pages/sprite_test.c
#SRCS += pages/ctrl_test.c
#SRCS += pages/fg_test.c
#SRCS += pages/bg_test.c
#SRCS += pages/z80_ctrl.c
else
SRCS += pages/$(PAGE).c
endif


BUILD_DIR = build/$(TARGET)
ROM_DIR = ../roms
PAGE_BUILD_ID := $(if $(strip $(PAGE)),$(PAGE),all-pages)
PAGE_STAMP := $(BUILD_DIR)/.page-$(PAGE_BUILD_ID)

OBJS = $(addprefix $(BUILD_DIR)/, $(SRCS:c=o)) \
	   $(addprefix $(BUILD_DIR)/, $(ASM:s=o))
BUILD_DIRS = $(sort $(dir $(OBJS))) 
GLOBAL_DEPS = Makefile

DEFINES = -DPRINTF_SUPPORT_DECIMAL_SPECIFIERS=0 \
	-DPRINTF_SUPPORT_EXPONENTIAL_SPECIFIERS=0 \
	-DPRINTF_SUPPORT_LONG_LONG=0 \
	-DPRINTF_ALIAS_STANDARD_FUNCTION_NAMES=1 \
	-DPRINTF_ALIAS_STANDARD_FUNCTION_NAMES_HARD=1

CFLAGS = -march=68000 -ffreestanding $(DEFINES) -O2 --std=c2x -g
LIBS = -lgcc
LDFLAGS = -march=68000 -static -nostdlib -g


ifeq ($(TARGET),pgm_test)
GAME = pgm
CPU_ROM  = pgm_p02s.u20
AUDIO_CPU_ROM = # audio_cpu.bin
DEFINES += -DGAME_PGM=1
else
error
endif

GAME_DIR = $(BUILD_DIR)/$(GAME)
BUILT_BINS = $(addprefix $(GAME_DIR)/, $(CPU_ROM) $(AUDIO_CPU_ROM))

ROMPATH = ../$(BUILD_DIR);../$(ROM_DIR)

all: $(BUILT_BINS)

$(BUILD_DIR)/cpu.bin: $(BUILD_DIR)/cpu.elf
	$(OBJCOPY) --pad-to 0x20000 --gap-fill 0xff -O binary -g --reverse-bytes 2 $< $@

$(GAME_DIR)/$(CPU_ROM): $(BUILD_DIR)/cpu.bin | $(GAME_DIR)
	cp $< $@

#$(GAME_DIR)/$(AUDIO_CPU_ROM): artemio/sound.asm | $(GAME_DIR)
#	$(VASM) -Fbin -nosym -chklabels -o $@ $<

$(BUILD_DIR)/%.o: %.c $(GLOBAL_DEPS) | $(BUILD_DIRS)
	@echo $@
	@$(CC) -MMD -o $@ $(CFLAGS) -c $<

$(BUILD_DIR)/%.o: %.s $(GLOBAL_DEPS) | $(BUILD_DIRS)
	@echo $@
	@$(CC) -MMD -o $@ $(CFLAGS) -c $<

$(BUILD_DIR)/%.o: %.chr $(GLOBAL_DEPS) | $(BUILD_DIRS)
	$(OBJCOPY) -I binary -O default $< $@

$(PAGE_STAMP): | $(BUILD_DIR)
	@rm -f $(BUILD_DIR)/.page-*
	@touch $@

$(BUILD_DIR)/cpu.elf: $(OBJS) $(GAME).ld $(PAGE_STAMP)
	@echo $@
	@$(CC) -T $(GAME).ld -o $@ $(LDFLAGS) $(OBJS) $(LIBS)
	@$(OBJDUMP) -d -S $@ > $(BUILD_DIR)/cpu.asm

$(BUILD_DIRS):
	mkdir -p $@

$(GAME_DIR):
	mkdir -p $@

$(BUILD_DIR)/$(TARGET).zip: $(BUILT_BINS)
	zip -j $(BUILD_DIR)/$(TARGET).zip $^

debug: $(BUILT_BINS)
	mkdir -p mame
	cd mame && ../$(MAME) -window -nomaximize -resolution0 640x480 -prescale 2 -debug -debugscript ../debugscript.txt -rompath "$(ROMPATH)" kovsh

run: $(BUILT_BINS)
	mkdir -p mame
	cd mame && ../$(MAME) -window -nomaximize -resolution0 640x480 -rompath "$(ROMPATH)" $(GAME)

picorom: $(BUILT_BINS)
	picorom reset pgm low
	picorom upload pgm $(GAME_DIR)/$(CPU_ROM)
	picorom reset pgm z

mister: $(BUILD_DIR)/$(TARGET).zip

.PHONY: run debug picorom mister

-include $(OBJS:o=d)
