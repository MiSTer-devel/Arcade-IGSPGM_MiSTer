#include "z80_ics_protocol.h"

#define ICS_PORT_STATUS 0x8000
#define ICS_PORT_REG    0x8001
#define ICS_PORT_LO     0x8002
#define ICS_PORT_HI     0x8003
#define LATCH1_PORT     0x8200
#define LATCH3_PORT     0x8100

#define ICS_REG_IRQV       0x0f
#define ICS_REG_TIMER0     0x40
#define ICS_REG_TIMER1     0x41
#define ICS_REG_TIMER_STAT 0x43
#define ICS_REG_OSC_SELECT 0x4f

#define ICS_STATUS_IRQ      0x80
#define ICS_STATUS_BUSY     0x40
#define ICS_STATUS_VOICEIRQ 0x02

#define SHARED ((volatile u8 *)Z80_ICS_SHARED_OFFSET)

static volatile u32 irq_timer0_count;
static volatile u32 irq_timer1_count;
static volatile u32 irq_osc_count;
static volatile u32 irq_vol_count;
static volatile u32 irq_spurious_count;

/* IRQ event ring: raw bytes seen by service_irq_c, in service order. */
static volatile u8 irq_log[Z80_ICS_IRQ_LOG_MAX * Z80_ICS_IRQ_LOG_ENTRY_SIZE];
static volatile u8 irq_log_seq;    /* free-running event number */
static volatile u8 irq_log_total;  /* saturates at Z80_ICS_IRQ_LOG_MAX */
static volatile u8 irq_consecutive_spurious;

static void irq_log_event(u8 kind, u8 a, u8 b)
{
    u8 idx = (u8)((irq_log_seq & (Z80_ICS_IRQ_LOG_MAX - 1)) << 2);
    irq_log[idx] = irq_log_seq;
    irq_log[idx + 1] = kind;
    irq_log[idx + 2] = a;
    irq_log[idx + 3] = b;
    irq_log_seq++;
    if (irq_log_total < Z80_ICS_IRQ_LOG_MAX)
        irq_log_total++;
}

static u8 ics_in_status(void) __naked
{
    __asm
        ld bc,#0x8000
        in a,(c)
        ret
    __endasm;
}

static u8 ics_in_lo(void) __naked
{
    __asm
        ld bc,#0x8002
        in a,(c)
        ret
    __endasm;
}

static u8 ics_in_hi(void) __naked
{
    __asm
        ld bc,#0x8003
        in a,(c)
        ret
    __endasm;
}

static void ics_out_reg(u8 value) __naked
{
    value;
    __asm
        ld bc,#0x8001
        out (c),a
        ret
    __endasm;
}

static void ics_out_lo(u8 value) __naked
{
    value;
    __asm
        ld bc,#0x8002
        out (c),a
        ret
    __endasm;
}

static void ics_out_hi(u8 value) __naked
{
    value;
    __asm
        ld bc,#0x8003
        out (c),a
        ret
    __endasm;
}

static u8 latch1_in(void) __naked
{
    __asm
        ld bc,#0x8200
        in a,(c)
        ret
    __endasm;
}

static u8 latch3_in(void) __naked
{
    __asm
        ld bc,#0x8100
        in a,(c)
        ret
    __endasm;
}

static u16 get16(u16 off)
{
    return ((u16)SHARED[off] << 8) | SHARED[off + 1];
}

static u32 get32(u16 off)
{
    return ((u32)SHARED[off] << 24) |
           ((u32)SHARED[off + 1] << 16) |
           ((u32)SHARED[off + 2] << 8) |
           SHARED[off + 3];
}

static void put16(u16 off, u16 value)
{
    SHARED[off] = (u8)(value >> 8);
    SHARED[off + 1] = (u8)value;
}

static void put32(u16 off, u32 value)
{
    SHARED[off] = (u8)(value >> 24);
    SHARED[off + 1] = (u8)(value >> 16);
    SHARED[off + 2] = (u8)(value >> 8);
    SHARED[off + 3] = (u8)value;
}

static void irq_disable(void) __naked
{
    __asm
        di
        ret
    __endasm;
}

static void irq_enable(void) __naked
{
    __asm
        ei
        ret
    __endasm;
}

static void ics_wait_idle(void)
{
    /* Do not poll the hardware busy bit here: hardware tests showed it is not
       reliable enough for this debug driver.  Still leave a fixed settle time
       between ICS host accesses.  Keep this conservative for real hardware; the
       BIOS routines are hand-written and have predictable instruction spacing,
       while this debug driver goes through C call glue. */
    __asm
        ld b,#128
    00001$:
        djnz 00001$
    __endasm;
}

static void ics_select_reg(u8 reg)
{
    ics_wait_idle();
    ics_out_reg(reg);
}

static void ics_select_voice(u8 voice)
{
    ics_select_reg(ICS_REG_OSC_SELECT);
    ics_out_lo(voice & 0x1f);
    ics_wait_idle();
}

static void ics_write_active_osc(void)
{
    /* Exact BIOS shape for WriteICSRegisterByteHigh(0x0e, 0x1f):
       OUT 8001,0e; OUT 8003,1f. */
    ics_select_reg(0x0e);
    ics_out_hi(0x1f);
    ics_wait_idle();
}

static u8 ics_reg_uses_voice_select(u8 reg)
{
    /* Match the BIOS/MAME split: most regs < 0x20 are oscillator/voice
       registers, but 0x0e is Active Oscillators and 0x0f is IRQV.  VMode
       register 0x12 is per-voice and uses the upper data port, so it still
       needs a preceding 0x4f oscillator select. */
    return reg < 0x20 && reg != 0x0e && reg != 0x0f;
}

static u16 ics_read_reg(u8 voice, u8 reg, u8 width)
{
    u16 result;
    if (ics_reg_uses_voice_select(reg))
        ics_select_voice(voice);
    ics_select_reg(reg);
    if (width == Z80_ICS_WIDTH_UPPER8)
        result = ics_in_hi();
    else if (width == Z80_ICS_WIDTH_LOWER8)
        result = ics_in_lo();
    else
    {
        result = ics_in_lo();
        result |= (u16)ics_in_hi() << 8;
    }
    return result;
}

static void ics_write_selected_reg(u8 reg, u8 width, u16 value)
{
    ics_select_reg(reg);
    if (width == Z80_ICS_WIDTH_UPPER8)
    {
        ics_out_hi((u8)value);
    }
    else if (width == Z80_ICS_WIDTH_LOWER8)
    {
        ics_out_lo((u8)value);
    }
    else
    {
        /* Match the BIOS word write helper: register select, then the 16-bit
           data port at 0x8002.  On Z80 this writes low byte first, then high. */
        ics_out_lo((u8)value);
        ics_out_hi((u8)(value >> 8));
    }
    ics_wait_idle();
}

static void ics_write_reg(u8 voice, u8 reg, u8 width, u16 value)
{
    if (ics_reg_uses_voice_select(reg))
        ics_select_voice(voice);
    ics_write_selected_reg(reg, width, value);
}

static void voice_put8(u16 *off, u8 v)
{
    SHARED[*off] = v;
    *off = *off + 1;
}

static void voice_put16(u16 *off, u16 v)
{
    put16(*off, v);
    *off = *off + 2;
}

static void voice_put32(u16 *off, u32 v)
{
    put32(*off, v);
    *off = *off + 4;
}

static u8 voice_get8(u16 *off)
{
    u8 v = SHARED[*off];
    *off = *off + 1;
    return v;
}

static u16 voice_get16(u16 *off)
{
    u16 v = get16(*off);
    *off = *off + 2;
    return v;
}

static u32 voice_get32(u16 *off)
{
    u32 v = get32(*off);
    *off = *off + 4;
    return v;
}

static void ics_read_voice(u8 voice)
{
    u16 off = Z80_ICS_OFF_VOICE_DATA;

    voice_put8(&off, (u8)ics_read_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8));
    voice_put16(&off, ics_read_reg(voice, 0x01, Z80_ICS_WIDTH_16));
    voice_put16(&off, ics_read_reg(voice, 0x02, Z80_ICS_WIDTH_16));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x03, Z80_ICS_WIDTH_UPPER8));
    voice_put16(&off, ics_read_reg(voice, 0x04, Z80_ICS_WIDTH_16));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x05, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x06, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x07, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x08, Z80_ICS_WIDTH_UPPER8));
    voice_put16(&off, ics_read_reg(voice, 0x09, Z80_ICS_WIDTH_16));
    voice_put16(&off, ics_read_reg(voice, 0x0a, Z80_ICS_WIDTH_16));
    voice_put16(&off, ics_read_reg(voice, 0x0b, Z80_ICS_WIDTH_16));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x0c, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x10, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x11, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, (u8)ics_read_reg(voice, 0x12, Z80_ICS_WIDTH_UPPER8));
    voice_put8(&off, 0);
}

static void ics_write_voice(u8 voice)
{
    u16 off = Z80_ICS_OFF_VOICE_DATA;
    u8 osc_conf = voice_get8(&off);
    u16 osc_fc = voice_get16(&off);
    u16 osc_start_hi = voice_get16(&off);
    u8 osc_start_lo = voice_get8(&off);
    u16 osc_end_hi = voice_get16(&off);
    u8 osc_end_lo = voice_get8(&off);
    u8 vol_incr = voice_get8(&off);
    u8 vol_start = voice_get8(&off);
    u8 vol_end = voice_get8(&off);
    u16 vol_acc = voice_get16(&off);
    u16 osc_acc_hi = voice_get16(&off);
    u16 osc_acc_lo = voice_get16(&off);
    u8 pan = voice_get8(&off);
    u8 vol_ctrl = voice_get8(&off);
    u8 osc_ctl = voice_get8(&off);
    u8 osc_saddr = voice_get8(&off);
    u8 vmode = voice_get8(&off);
    (void)voice_get8(&off);

    /* Hardware-parity PLAY path: select voice once, then emit the same register
       order observed from z80_sound_test / BIOS ProgramSoundChannelRegisters.
       Do not re-select 0x4f before every voice register in this path. */
    ics_select_voice(voice);
    ics_write_selected_reg(0x10, Z80_ICS_WIDTH_UPPER8, 0x0f);
    ics_write_selected_reg(0x01, Z80_ICS_WIDTH_16, osc_fc);
    ics_write_selected_reg(0x11, Z80_ICS_WIDTH_UPPER8, osc_saddr);
    ics_write_selected_reg(0x12, Z80_ICS_WIDTH_UPPER8, vmode);
    ics_write_selected_reg(0x0b, Z80_ICS_WIDTH_16, osc_acc_lo);
    ics_write_selected_reg(0x0a, Z80_ICS_WIDTH_16, osc_acc_hi);
    ics_write_selected_reg(0x03, Z80_ICS_WIDTH_UPPER8, osc_start_lo);
    ics_write_selected_reg(0x02, Z80_ICS_WIDTH_16, osc_start_hi);
    ics_write_selected_reg(0x05, Z80_ICS_WIDTH_UPPER8, osc_end_lo);
    ics_write_selected_reg(0x04, Z80_ICS_WIDTH_16, osc_end_hi);
    ics_write_selected_reg(0x0c, Z80_ICS_WIDTH_UPPER8, pan);
    ics_write_selected_reg(0x06, Z80_ICS_WIDTH_UPPER8, vol_incr);
    ics_write_selected_reg(0x07, Z80_ICS_WIDTH_UPPER8, vol_start);
    ics_write_selected_reg(0x08, Z80_ICS_WIDTH_UPPER8, vol_end);
    ics_write_selected_reg(0x09, Z80_ICS_WIDTH_16, vol_acc);
    ics_write_selected_reg(0x00, Z80_ICS_WIDTH_UPPER8, osc_conf);
    ics_write_selected_reg(0x0d, Z80_ICS_WIDTH_UPPER8, vol_ctrl);
    ics_write_selected_reg(0x10, Z80_ICS_WIDTH_UPPER8, osc_ctl);
}

static void ics_init_chip(void)
{
    u8 voice;
    u8 sys;
    u8 i;

    /* BIOS ResetSoundChipMixerState:
       write system-control 0x4d = 0, burn reads, then 0x4d = 1. */
    ics_write_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8, 0x00);
    for (i = 0; i < 16; i++)
        (void)ics_read_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8);
    ics_write_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8, 0x01);

    /* BIOS writes 0x4c = 3 before the voice/table init path.  MAME labels this
       area as memory/system config; real hardware may need it for the host
       oscillator-register bank to behave predictably. */
    ics_write_reg(0, 0x4c, Z80_ICS_WIDTH_LOWER8, 0x03);

    /* BIOS clears bit 3 of system control while initializing voices. */
    sys = (u8)ics_read_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8);
    ics_write_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8, sys & 0xf7);

    ics_write_active_osc();

    for (voice = 0; voice < 32; voice++)
    {
        ics_write_reg(voice, 0x10, Z80_ICS_WIDTH_UPPER8, 0x0f); /* stop */
        ics_write_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8, 0x00);
        ics_write_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8, 0x03);
        ics_write_reg(voice, 0x07, Z80_ICS_WIDTH_UPPER8, 0x01);
        ics_write_reg(voice, 0x08, Z80_ICS_WIDTH_UPPER8, 0x01);
    }

    /* BIOS writes active oscillators again near the end of its init path. */
    ics_write_active_osc();

    /* BIOS then enables system-control bits 2 and 3 and IRQ enable bit 0. */
    sys = (u8)ics_read_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8);
    ics_write_reg(0, 0x4d, Z80_ICS_WIDTH_LOWER8, sys | 0x0c);
    ics_write_reg(0, 0x4a, Z80_ICS_WIDTH_LOWER8, 0x01);

    ics_select_voice(0);
}

static void publish_irq_counts(void)
{
    put32(Z80_ICS_OFF_TIMER0, irq_timer0_count);
    put32(Z80_ICS_OFF_TIMER1, irq_timer1_count);
    put32(Z80_ICS_OFF_OSC_IRQ, irq_osc_count);
    put32(Z80_ICS_OFF_VOL_IRQ, irq_vol_count);
    put32(Z80_ICS_OFF_SPURIOUS, irq_spurious_count);
}

static void reset_irq_counts(void)
{
    irq_timer0_count = 0;
    irq_timer1_count = 0;
    irq_osc_count = 0;
    irq_vol_count = 0;
    irq_spurious_count = 0;
}

static void publish_irq_log(void)
{
    u8 count = irq_log_total;
    u8 start = (u8)((irq_log_seq - count) & (Z80_ICS_IRQ_LOG_MAX - 1));
    u8 i;
    put16(Z80_ICS_OFF_LOG_COUNT, count);
    for (i = 0; i < count; i++)
    {
        u8 src = (u8)(((start + i) & (Z80_ICS_IRQ_LOG_MAX - 1)) << 2);
        u16 dst = (u16)(Z80_ICS_OFF_LOG_DATA + ((u16)i << 2));
        SHARED[dst] = irq_log[src];
        SHARED[dst + 1] = irq_log[src + 1];
        SHARED[dst + 2] = irq_log[src + 2];
        SHARED[dst + 3] = irq_log[src + 3];
    }
}

static void clear_irq_log(void)
{
    irq_log_seq = 0;
    irq_log_total = 0;
}

static void service_irq_c(void)
{
    u8 status = ics_in_status();
    u8 handled = 0;

    if (status & ICS_STATUS_IRQ)
    {
        u8 timer_status = (u8)ics_read_reg(0, ICS_REG_TIMER_STAT, Z80_ICS_WIDTH_LOWER8);
        if (timer_status & 0x03)
            irq_log_event(Z80_ICS_IRQ_LOG_KIND_TIMER, timer_status, status);
        if (timer_status & 0x01)
        {
            irq_timer0_count++;
            (void)ics_read_reg(0, ICS_REG_TIMER0, Z80_ICS_WIDTH_LOWER8);
            handled = 1;
        }
        if (timer_status & 0x02)
        {
            irq_timer1_count++;
            (void)ics_read_reg(0, ICS_REG_TIMER1, Z80_ICS_WIDTH_LOWER8);
            handled = 1;
        }

        for (;;)
        {
            u8 vstatus = ics_in_status();
            u8 irqv;
            u8 voice;
            if (!(vstatus & ICS_STATUS_VOICEIRQ))
                break;
            /* BIOS reads 0x0f directly; it is an IRQ source register even
               though it lives in the low register-number range. */
            ics_select_reg(ICS_REG_IRQV);
            irqv = ics_in_hi();
            irq_log_event(Z80_ICS_IRQ_LOG_KIND_IRQV, irqv, vstatus);
            if ((irqv & 0xe0) == 0xe0)
                break;
            voice = irqv & 0x1f;
            /* On real hardware the INT level follows the stored per-voice
               pending bits, not the IRQV read: ack by clearing OscConf bit7
               / VCtl bit7 on the reported voice (the BIOS achieves this via
               its voice-teardown rewrite).  Reading IRQV alone storms. */
            if ((irqv & 0x80) == 0)
            {
                u8 conf = (u8)ics_read_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8);
                /* The INT level follows (source condition & enable): clearing
                   bit7 alone re-asserts immediately (measured: 12k services).
                   Clear the enable too, BIOS-teardown style. */
                ics_write_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8, conf & 0x5f);
                irq_osc_count++;
            }
            if ((irqv & 0x40) == 0)
            {
                u8 vctl = (u8)ics_read_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8);
                ics_write_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8, vctl & 0x5f);
                irq_vol_count++;
            }
            handled = 1;
        }
    }

    if (!handled)
    {
        /* Hardware can assert INT without the status VOICEIRQ bit: attempt
           a voice ack via IRQV anyway before declaring the IRQ spurious. */
        u8 irqv;
        ics_select_reg(ICS_REG_IRQV);
        irqv = ics_in_hi();
        if ((irqv & 0xe0) != 0xe0)
        {
            u8 voice = irqv & 0x1f;
            irq_log_event(Z80_ICS_IRQ_LOG_KIND_IRQV, irqv, status);
            if ((irqv & 0x80) == 0)
            {
                u8 conf = (u8)ics_read_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8);
                ics_write_reg(voice, 0x00, Z80_ICS_WIDTH_UPPER8, conf & 0x5f);
                irq_osc_count++;
            }
            if ((irqv & 0x40) == 0)
            {
                u8 vctl = (u8)ics_read_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8);
                ics_write_reg(voice, 0x0d, Z80_ICS_WIDTH_UPPER8, vctl & 0x5f);
                irq_vol_count++;
            }
            irq_consecutive_spurious = 0;
            return;
        }
        irq_spurious_count++;
        irq_log_event(Z80_ICS_IRQ_LOG_KIND_SPURIOUS, status, irqv);
        /* Storm guard: a level INT we cannot ack would starve the main loop
           forever.  After 16 consecutive unresolvable IRQs, drop the 0x4A
           gate and log it so the host sees what happened. */
        if (++irq_consecutive_spurious >= 16)
        {
            ics_write_reg(0, 0x4a, Z80_ICS_WIDTH_LOWER8, 0x00);
            irq_log_event(Z80_ICS_IRQ_LOG_KIND_SPURIOUS, 0xEE, status);
            irq_consecutive_spurious = 0;
        }
    }
    else
    {
        irq_consecutive_spurious = 0;
    }
}

static void process_command(void)
{
    u8 cmd;
    u8 voice;
    u8 reg;
    u8 width;
    u16 value;
    u8 error = Z80_ICS_ERR_NONE;

    if (get16(Z80_ICS_OFF_MAGIC) != Z80_ICS_MAGIC)
    {
        SHARED[Z80_ICS_OFF_ERROR] = Z80_ICS_ERR_BAD_MAGIC;
        SHARED[Z80_ICS_OFF_STATUS] = Z80_ICS_STATUS_ERROR;
        return;
    }

    cmd = SHARED[Z80_ICS_OFF_CMD];
    voice = SHARED[Z80_ICS_OFF_VOICE] & 0x1f;
    reg = SHARED[Z80_ICS_OFF_REG];
    width = SHARED[Z80_ICS_OFF_WIDTH];
    value = get16(Z80_ICS_OFF_VALUE);

    /* The ICS host interface has one shared register selector and one shared
       oscillator selector.  The IRQ handler also talks to the ICS, so do not
       allow it to interleave between select/data phases of a debug command. */
    irq_disable();

    switch (cmd)
    {
    case Z80_ICS_CMD_PING:
        put16(Z80_ICS_OFF_RESULT, Z80_ICS_DRIVER_MAGIC);
        publish_irq_counts();
        break;

    case Z80_ICS_CMD_READ_REG:
        if (width > Z80_ICS_WIDTH_LOWER8)
            error = Z80_ICS_ERR_BAD_WIDTH;
        else
            put16(Z80_ICS_OFF_RESULT, ics_read_reg(voice, reg, width));
        break;

    case Z80_ICS_CMD_WRITE_REG:
        if (width > Z80_ICS_WIDTH_LOWER8)
            error = Z80_ICS_ERR_BAD_WIDTH;
        else
            ics_write_reg(voice, reg, width, value);
        break;

    case Z80_ICS_CMD_READ_VOICE:
        ics_read_voice(voice);
        break;

    case Z80_ICS_CMD_WRITE_VOICE:
        ics_write_voice(voice);
        break;

    case Z80_ICS_CMD_GET_IRQ_COUNTS:
        publish_irq_counts();
        break;

    case Z80_ICS_CMD_RESET_IRQ_COUNTS:
        reset_irq_counts();
        publish_irq_counts();
        break;

    case Z80_ICS_CMD_GET_IRQ_LOG:
        publish_irq_log();
        break;

    case Z80_ICS_CMD_CLEAR_IRQ_LOG:
        clear_irq_log();
        publish_irq_log();
        break;

    case Z80_ICS_CMD_READ_STATUS:
        put16(Z80_ICS_OFF_RESULT, ics_in_status());
        break;

    default:
        error = Z80_ICS_ERR_BAD_CMD;
        break;
    }

    SHARED[Z80_ICS_OFF_ERROR] = error;
    SHARED[Z80_ICS_OFF_STATUS] = error ? Z80_ICS_STATUS_ERROR : Z80_ICS_STATUS_DONE;
    irq_enable();
}

void z80_ics_nmi(void) __naked
{
    __asm
        push af
        push bc
        push hl
        ld hl,#0x0200
        call _latch1_in
        pop hl
        pop bc
        pop af
        retn
    __endasm;
}

void z80_ics_isr(void) __naked
{
    __asm
        push af
        push bc
        push de
        push hl
        push ix
        push iy
        call _service_irq_c
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        reti
    __endasm;
}

void main(void)
{
    u8 last_seq = 0;
    reset_irq_counts();
    ics_init_chip();
    put16(Z80_ICS_OFF_MAGIC, Z80_ICS_MAGIC);
    SHARED[Z80_ICS_OFF_SEQ] = 0;
    SHARED[Z80_ICS_OFF_CMD] = 0;
    SHARED[Z80_ICS_OFF_STATUS] = Z80_ICS_STATUS_READY;
    SHARED[Z80_ICS_OFF_ERROR] = 0;
    publish_irq_counts();

    __asm
        im 1
        ei
    __endasm;

    while (1)
    {
        u8 seq = SHARED[Z80_ICS_OFF_SEQ];
        if (SHARED[Z80_ICS_OFF_STATUS] == Z80_ICS_STATUS_BUSY && seq != last_seq)
        {
            last_seq = seq;
            process_command();
        }
    }
}
