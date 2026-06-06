// HDL source files compiled by the Verilator simulator build.
// Mirrors HDL_SRC in sim/Makefile (USE_AUTO_SS=1 variant, the default build).
// Paths are relative to the repository root.

// fx68k 68000 core (Verilator variant)
rtl/fx68k/hdl/verilator/fx68k.sv
rtl/fx68k/hdl/verilator/fx68kAlu.sv
rtl/fx68k/hdl/verilator/uaddrPla.sv

// PGM core
rtl/system_consts.sv
rtl/address_translator.sv
rtl/rom_cache.sv
rtl/PGM.sv
rtl/video_timing.sv
rtl/ram.sv
rtl/jtframe_frac_cen.v
rtl/memory_stream.sv
rtl/savestates.sv
rtl/ddram.sv
rtl/audio_mix.sv
sys/iir_filter.v
rtl/rom_loader.sv
rtl/rom_decrypt.sv

// IGS023 graphics
rtl/igs023.sv
rtl/igs023_fg.sv
rtl/igs023_bg.sv
rtl/igs023_sprite.sv
rtl/igs023_buffer.sv

// protection devices
rtl/igs026_x.sv
rtl/pgm_asic3.sv
rtl/igs025_src_tables.sv
rtl/igs025.sv
rtl/igs022.sv

// ARM7TDMI + IGS027A
rtl/ARM7TDMI/Alu.sv
rtl/ARM7TDMI/Shifter.sv
rtl/ARM7TDMI/Multiplier.sv
rtl/ARM7TDMI/Decoder.sv
rtl/ARM7TDMI/Control.sv
rtl/ARM7TDMI/ARM7TDMI.sv
rtl/arm_rom_cache.sv
rtl/prot_cache.sv
rtl/ram_cache.sv
rtl/igs027a.sv

// RTC
rtl/v3021.sv

// ICS2115 sound
rtl/ics2115/ics2115_pkg.sv
rtl/ics2115/ics2115.sv
rtl/ics2115/ics2115_osc.sv
rtl/ics2115/ics2115_tables.sv

// Z80 + FM (auto-savestate variants)
rtl/tv80_auto_ss.sv
rtl/jt10_auto_ss.sv

// simulator top
sim/sim_top.sv
