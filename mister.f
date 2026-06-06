// HDL source files compiled by the MiSTer Quartus build.
// Mirrors files.qip (core) and sys/sys.qip (MiSTer framework), as pulled in by
// Arcade-IGSPGM.qsf.  Paths are relative to the repository root.
// Quartus IP wrappers (.qip), constraints (.sdc) and generated PLLs are not
// listed here, only HDL source.

// ---- top ----
Arcade-IGSPGM.sv

// fx68k 68000 core
rtl/fx68k/hdl/fx68k.sv
rtl/fx68k/hdl/fx68kAlu.sv
rtl/fx68k/hdl/uaddrPla.sv

// PGM core
rtl/pause.sv
rtl/savestate_ui.sv
rtl/sdram.sv
rtl/system_consts.sv
rtl/PGM.sv

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
rtl/rom_decrypt.sv

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

// PGM core (cont.)
rtl/address_translator.sv
rtl/ram.sv
rtl/jtframe_frac_cen.v
rtl/jtframe_resync.v
rtl/memory_stream.sv
rtl/savestates.sv
rtl/ddram.sv
rtl/rom_loader.sv
rtl/audio_mix.sv
rtl/video_path.sv
rtl/rom_cache.sv
rtl/mame_keys.sv
rtl/coin_pulse.sv
rtl/video_timing.sv

// ICS2115 sound
rtl/ics2115/ics2115_pkg.sv
rtl/ics2115/ics2115.sv
rtl/ics2115/ics2115_tables.sv
rtl/ics2115/ics2115_osc.sv

// Z80 + FM (auto-savestate variants)
rtl/tv80_auto_ss.sv
rtl/jt10_auto_ss.sv

// ---- MiSTer framework (sys/sys.qip) ----
sys/sys_top.v
sys/ascal.vhd
sys/pll_hdmi_adj.vhd
sys/math.sv
sys/hq2x.sv
sys/scandoubler.v
sys/scanlines.v
sys/shadowmask.sv
sys/video_cleaner.sv
sys/gamma_corr.sv
sys/video_mixer.sv
sys/video_freak.sv
sys/video_freezer.sv
sys/arcade_video.v
sys/osd.v
sys/vga_out.sv
sys/yc_out.sv
sys/i2c.v
sys/alsa.sv
sys/i2s.v
sys/spdif.v
sys/audio_out.v
sys/iir_filter.v
sys/ltc2308.sv
sys/sigma_delta_dac.v
sys/mt32pi.sv
sys/mcp23009.sv
sys/f2sdram_safe_terminator.sv
sys/ddr_svc.sv
sys/sysmem.sv
sys/sd_card.sv
sys/hps_io.sv
