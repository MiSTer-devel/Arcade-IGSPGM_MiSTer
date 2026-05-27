// ICS2115 WaveFront Synthesizer — Shared Package
// All types, constants, enums, and bit-position parameters used across modules.

package ics2115_pkg;

    // =========================================================================
    // Chip constants
    // =========================================================================
    localparam CHIP_REVISION      = 8'h01;
    localparam NUM_VOICES         = 32;
    localparam DEFAULT_ACTIVE_OSC = 5'd31;
    localparam VOLUME_BITS        = 15;          // volume table output width
    localparam VOLUME_TABLE_SIZE  = 4096;
    localparam PAN_TABLE_SIZE     = 256;
    localparam ULAW_TABLE_SIZE    = 256;

    // =========================================================================
    // OscCtl (register 0x10)
    localparam OSC_DONE      = 0;
    localparam OSC_STOP      = 1;

    // =========================================================================
    // OscConf (register 0x00) bit positions — use localparam, not enum
    // Spec §4.3: [7] irq_pending | [6] invert | [5] irq_en | [4] bidir |
    //            [3] loop | [2] 8-bit | [1] stop | [0] µ-law
    // =========================================================================
    localparam OSC_ULAW      = 0;
    localparam OSC_EIGHTBIT  = 1;
    localparam OSC_LOOP      = 3;
    localparam OSC_BIDIR     = 4;
    localparam OSC_IRQ       = 5;
    localparam OSC_INVERT    = 6;
    localparam OSC_IRQ_PEND  = 7;

    // =========================================================================
    // VolCtrl (register 0x0D) bit positions
    // Spec §4.3: [7] irq_pending | [6] invert | [5] irq_en | [4] bidir |
    //            [3] loop | [2] rollover | [1] stop | [0] done
    // =========================================================================
    localparam VOL_DONE      = 0;
    localparam VOL_STOP      = 1;
    localparam VOL_ROLLOVER  = 2;
    localparam VOL_LOOP      = 3;
    localparam VOL_BIDIR     = 4;
    localparam VOL_IRQ       = 5;
    localparam VOL_INVERT    = 6;
    localparam VOL_IRQ_PEND  = 7;

    // =========================================================================
    // Voice state structure — packed struct with explicit bit widths per spec §2
    //
    // osc_acc:   29-bit (20.9 fixed-point) — sample position accumulator
    // osc_fc:    16-bit frequency counter (bit 0 unused, always 0)
    // osc_start: 29-bit (20.9) — loop start address
    // osc_end:   29-bit (20.9) — loop end address
    // osc_saddr: 8-bit — static address bank selector (bits 27-20 of ROM addr)
    // osc_conf:  8-bit — oscillator configuration flags
    // osc_ctl:   8-bit — oscillator control register
    //
    // vol_acc:   26-bit — volume envelope accumulator (regacc << 10)
    // vol_start: 26-bit — volume envelope start
    // vol_end:   26-bit — volume envelope end
    // vol_incr:  8-bit — volume increment register
    // vol_pan:   8-bit — pan value (0-255)
    // vol_ctrl:  8-bit — volume control flags
    // vol_mode:  8-bit — per-voice volume envelope mode (REG_VMODE, low 2 bits significant)
    //
    // state_on:   1-bit — voice is keyed on
    // =========================================================================
    typedef struct packed {
        // Oscillator fields
        logic [28:0] osc_acc;     // 20.9 fixed-point address accumulator
        logic [15:0] osc_fc;      // frequency counter (bit 0 unused, step = fc[15:1])
        logic [28:0] osc_start;   // loop start address (20.9)
        logic [28:0] osc_end;     // loop end address (20.9)
        logic [7:0]  osc_saddr;   // sample bank address (bits 27-20)
        logic [7:0]  osc_conf;    // oscillator config flags
        logic [7:0]  osc_ctl;     // oscillator control register

        // Volume envelope fields
        logic [25:0] vol_acc;     // envelope accumulator (regacc << 10)
        logic [25:0] vol_start;   // envelope start
        logic [25:0] vol_end;     // envelope end
        logic [7:0]  vol_incr;    // increment register
        logic [7:0]  vol_pan;     // pan value (0-255)
        logic [7:0]  vol_ctrl;    // volume control flags
        logic [7:0]  vol_mode;    // volume envelope mode (low 2 bits significant)

        // Voice runtime state
        logic        state_on;    // voice is keyed on
    } voice_state_t;

    // =========================================================================
    // Register addresses — per-voice (0x00–0x1F), written via indirect access
    // =========================================================================
    localparam REG_OSC_CONF     = 8'h00;
    localparam REG_OSC_FC       = 8'h01;
    localparam REG_OSC_START_H  = 8'h02;
    localparam REG_OSC_START_L  = 8'h03;
    localparam REG_OSC_END_H    = 8'h04;
    localparam REG_OSC_END_L    = 8'h05;
    localparam REG_VOL_INCR     = 8'h06;
    localparam REG_VOL_START    = 8'h07;
    localparam REG_VOL_END      = 8'h08;
    localparam REG_VOL_ACC      = 8'h09;
    localparam REG_OSC_ACC_H    = 8'h0A;
    localparam REG_OSC_ACC_L    = 8'h0B;
    localparam REG_PAN          = 8'h0C;
    localparam REG_VOL_CTRL     = 8'h0D;
    localparam REG_ACTIVE_OSC   = 8'h0E;
    localparam REG_IRQV         = 8'h0F;
    localparam REG_OSC_CTL      = 8'h10;
    localparam REG_OSC_SADDR    = 8'h11;
    localparam REG_VMODE        = 8'h12;

    // General-purpose registers (0x40–0x7F)
    localparam REG_TIMER1       = 8'h40;
    localparam REG_TIMER2       = 8'h41;
    localparam REG_TIMER1_PRES  = 8'h42;
    localparam REG_TIMER2_PRES  = 8'h43;
    localparam REG_IRQ_ENABLE   = 8'h4A;
    localparam REG_CHIP_REV     = 8'h4C;
    localparam REG_OSC_NUMBER   = 8'h4F;

endpackage
