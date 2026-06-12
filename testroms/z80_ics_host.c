#include <stddef.h>

#include "z80_ics_host.h"
#include "z80_ics_driver_data.h"

#define Z80_LATCH1      (*(volatile u16 *)0x00c00002)
#define Z80_LATCH2      (*(volatile u16 *)0x00c00004)
#define Z80_RESET_REG   (*(volatile u16 *)0x00c00008)
#define Z80_CONTROL_REG (*(volatile u16 *)0x00c0000a)
#define Z80_LATCH3      (*(volatile u16 *)0x00c0000c)
#define Z80_RAM16       ((volatile u16 *)0x00c10000)

#define Z80_CONTROL_BUS_68K 0x45d3
#define Z80_CONTROL_RUN     0x0a0a
#define Z80_RESET_ASSERT    0xa659
#define Z80_RESET_RELEASE   0x5050

#define Z80_POLL_LIMIT      0x20000UL

static u8 s_seq;
static u16 s_last_error;
static u16 s_last_status;
static bool s_ready;

static void delay_short(u16 count)
{
    volatile u16 i;
    for (i = 0; i < count; i++)
    {
    }
}

static void z80_bus_take(void)
{
    Z80_CONTROL_REG = Z80_CONTROL_BUS_68K;
    /* Match the BIOS pattern: write 0x45d3, then a short software delay. */
    delay_short(5);
}

static void z80_bus_release(void)
{
    Z80_CONTROL_REG = Z80_CONTROL_RUN;
    delay_short(5);
}

static u16 z80_read_word(u16 offset)
{
    return Z80_RAM16[offset >> 1];
}

static void z80_write_word(u16 offset, u16 value)
{
    Z80_RAM16[offset >> 1] = value;
}

static void z80_write_bytes_as_words(u16 offset, const u8 *src, u16 size)
{
    u16 i;
    for (i = 0; i < size; i += 2, offset += 2)
    {
        u16 value = (u16)src[i] << 8;
        if ((u16)(i + 1) < size)
            value |= src[i + 1];
        z80_write_word(offset, value);
    }
}

static void z80_fill_words(u16 value)
{
    for (u32 i = 0; i < 0x8000; i++)
        Z80_RAM16[i] = value;
}

static u16 shared_off(u16 off)
{
    return (u16)(Z80_ICS_SHARED_OFFSET + off);
}

static u16 shared_read16(u16 off)
{
    return z80_read_word(shared_off(off));
}

static u32 shared_read32(u16 off)
{
    return ((u32)shared_read16(off) << 16) | shared_read16(off + 2);
}

static void shared_write16(u16 off, u16 value)
{
    z80_write_word(shared_off(off), value);
}

static void shared_write32(u16 off, u32 value)
{
    shared_write16(off, (u16)(value >> 16));
    shared_write16(off + 2, (u16)value);
}

static void shared_write_voice(u16 off, const z80_ics_voice_t *voice)
{
    const u8 *src = (const u8 *)voice;
    for (u16 i = 0; i < Z80_ICS_VOICE_SIZE; i += 2)
    {
        u16 value = (u16)src[i] << 8;
        if ((u16)(i + 1) < Z80_ICS_VOICE_SIZE)
            value |= src[i + 1];
        shared_write16((u16)(off + i), value);
    }
}

static void shared_read_voice(u16 off, z80_ics_voice_t *voice)
{
    u8 *dst = (u8 *)voice;
    for (u16 i = 0; i < Z80_ICS_VOICE_SIZE; i += 2)
    {
        u16 value = shared_read16((u16)(off + i));
        dst[i] = (u8)(value >> 8);
        if ((u16)(i + 1) < Z80_ICS_VOICE_SIZE)
            dst[i + 1] = (u8)value;
    }
}

static bool wait_ready_status(void)
{
    for (u32 i = 0; i < Z80_POLL_LIMIT; i++)
    {
        u16 magic;
        u16 status_error;

        delay_short(50);
        z80_bus_take();
        magic = shared_read16(Z80_ICS_OFF_MAGIC);
        status_error = shared_read16(Z80_ICS_OFF_STATUS);
        z80_bus_release();

        if (magic == Z80_ICS_MAGIC && (u8)(status_error >> 8) == Z80_ICS_STATUS_READY)
            return true;
    }
    return false;
}

void z80_ics_init(void)
{
    s_ready = false;
    s_seq = 0;
    s_last_error = 0;
    s_last_status = 0;

    Z80_CONTROL_REG = Z80_CONTROL_BUS_68K;
    Z80_RESET_REG = Z80_RESET_ASSERT;
    delay_short(5);

    z80_fill_words(0x0000);
    z80_write_bytes_as_words(0, z80_ics_driver_blob, (u16)z80_ics_driver_blob_size);

    for (u16 off = 0; off < Z80_ICS_SHARED_SIZE; off += 2)
        z80_write_word((u16)(Z80_ICS_SHARED_OFFSET + off), 0);

    delay_short(10);
    Z80_CONTROL_REG = Z80_CONTROL_RUN;
    delay_short(10);
    Z80_RESET_REG = Z80_RESET_RELEASE;

    s_ready = wait_ready_status();
}

bool z80_ics_ready(void)
{
    return s_ready;
}

u16 z80_ics_last_error(void)
{
    return s_last_error;
}

u16 z80_ics_last_status(void)
{
    return s_last_status;
}

u8 z80_ics_last_seq(void)
{
    return s_seq;
}

static bool command_begin(u8 cmd, u8 voice, u8 reg, u8 width, u16 value, const z80_ics_voice_t *voice_data)
{
    if (!s_ready)
        return false;

    s_seq++;
    if (s_seq == 0)
        s_seq = 1;

    const u16 seq_cmd = ((u16)s_seq << 8) | cmd;
    const u16 ready_ok = ((u16)Z80_ICS_STATUS_READY << 8) | Z80_ICS_ERR_NONE;
    const u16 busy_ok = ((u16)Z80_ICS_STATUS_BUSY << 8) | Z80_ICS_ERR_NONE;

    for (u16 retry = 0; retry < 256; retry++)
    {
        z80_bus_take();
        delay_short(16);

        shared_write16(Z80_ICS_OFF_MAGIC, Z80_ICS_MAGIC);
        shared_write16(Z80_ICS_OFF_STATUS, ready_ok);
        shared_write16(Z80_ICS_OFF_SEQ, seq_cmd);
        shared_write16(Z80_ICS_OFF_VOICE, ((u16)voice << 8) | reg);
        shared_write16(Z80_ICS_OFF_WIDTH, ((u16)width << 8));
        shared_write16(Z80_ICS_OFF_VALUE, value);
        shared_write16(Z80_ICS_OFF_RESULT, 0);
        if (voice_data)
            shared_write_voice(Z80_ICS_OFF_VOICE_DATA, voice_data);

        if (shared_read16(Z80_ICS_OFF_MAGIC) == Z80_ICS_MAGIC &&
            shared_read16(Z80_ICS_OFF_SEQ) == seq_cmd &&
            shared_read16(Z80_ICS_OFF_VOICE) == (((u16)voice << 8) | reg) &&
            shared_read16(Z80_ICS_OFF_WIDTH) == ((u16)width << 8) &&
            shared_read16(Z80_ICS_OFF_VALUE) == value)
        {
            shared_write16(Z80_ICS_OFF_STATUS, busy_ok);
            z80_bus_release();
            Z80_LATCH3 = s_seq;
            delay_short(200);
            return true;
        }

        z80_bus_release();
        delay_short(50);
    }

    s_last_status = Z80_ICS_STATUS_ERROR;
    s_last_error = Z80_ICS_ERR_TIMEOUT;
    return false;
}

static bool command_wait(void)
{
    for (u32 i = 0; i < Z80_POLL_LIMIT; i++)
    {
        u16 seq_cmd;
        u16 status_error;
        u8 seq;
        u8 status;
        u8 error;

        delay_short(50);
        z80_bus_take();
        seq_cmd = shared_read16(Z80_ICS_OFF_SEQ);
        status_error = shared_read16(Z80_ICS_OFF_STATUS);
        z80_bus_release();

        seq = (u8)(seq_cmd >> 8);
        status = (u8)(status_error >> 8);
        error = (u8)status_error;

        if (seq == s_seq && (status == Z80_ICS_STATUS_DONE || status == Z80_ICS_STATUS_ERROR))
        {
            s_last_status = status;
            s_last_error = error;
            return status == Z80_ICS_STATUS_DONE && error == Z80_ICS_ERR_NONE;
        }
    }

    s_last_status = Z80_ICS_STATUS_ERROR;
    s_last_error = Z80_ICS_ERR_TIMEOUT;
    return false;
}

static bool command_simple(u8 cmd, u8 voice, u8 reg, u8 width, u16 value, const z80_ics_voice_t *voice_data)
{
    return command_begin(cmd, voice, reg, width, value, voice_data) && command_wait();
}

bool z80_ics_ping(u16 *driver_magic)
{
    if (!command_simple(Z80_ICS_CMD_PING, 0, 0, 0, 0, NULL))
        return false;
    if (driver_magic)
    {
        z80_bus_take();
        *driver_magic = shared_read16(Z80_ICS_OFF_RESULT);
        z80_bus_release();
    }
    return true;
}

bool z80_ics_read_reg(u8 voice, u8 reg, u8 width, u16 *result)
{
    if (!command_simple(Z80_ICS_CMD_READ_REG, voice, reg, width, 0, NULL))
        return false;
    if (result)
    {
        z80_bus_take();
        *result = shared_read16(Z80_ICS_OFF_RESULT);
        z80_bus_release();
    }
    return true;
}

bool z80_ics_write_reg(u8 voice, u8 reg, u8 width, u16 value)
{
    return command_simple(Z80_ICS_CMD_WRITE_REG, voice, reg, width, value, NULL);
}

bool z80_ics_read_voice(u8 voice, z80_ics_voice_t *out)
{
    if (!command_simple(Z80_ICS_CMD_READ_VOICE, voice, 0, 0, 0, NULL))
        return false;
    if (out)
    {
        z80_bus_take();
        shared_read_voice(Z80_ICS_OFF_VOICE_DATA, out);
        z80_bus_release();
    }
    return true;
}

bool z80_ics_write_voice(u8 voice, const z80_ics_voice_t *in)
{
    return command_simple(Z80_ICS_CMD_WRITE_VOICE, voice, 0, 0, 0, in);
}

static void read_irq_counts_from_shared(z80_ics_irq_counts_t *out)
{
    if (!out)
        return;
    out->timer0 = shared_read32(Z80_ICS_OFF_TIMER0);
    out->timer1 = shared_read32(Z80_ICS_OFF_TIMER1);
    out->osc = shared_read32(Z80_ICS_OFF_OSC_IRQ);
    out->vol = shared_read32(Z80_ICS_OFF_VOL_IRQ);
    out->spurious = shared_read32(Z80_ICS_OFF_SPURIOUS);
}

bool z80_ics_get_irq_counts(z80_ics_irq_counts_t *out)
{
    if (!command_simple(Z80_ICS_CMD_GET_IRQ_COUNTS, 0, 0, 0, 0, NULL))
        return false;
    z80_bus_take();
    read_irq_counts_from_shared(out);
    z80_bus_release();
    return true;
}

bool z80_ics_reset_irq_counts(z80_ics_irq_counts_t *out)
{
    if (!command_simple(Z80_ICS_CMD_RESET_IRQ_COUNTS, 0, 0, 0, 0, NULL))
        return false;
    z80_bus_take();
    read_irq_counts_from_shared(out);
    z80_bus_release();
    return true;
}

bool z80_ics_get_irq_log(z80_ics_irq_log_entry_t *entries, u8 *count)
{
    u16 n;
    if (!command_simple(Z80_ICS_CMD_GET_IRQ_LOG, 0, 0, 0, 0, NULL))
        return false;
    z80_bus_take();
    n = shared_read16(Z80_ICS_OFF_LOG_COUNT);
    if (n > Z80_ICS_IRQ_LOG_MAX)
        n = Z80_ICS_IRQ_LOG_MAX;
    for (u16 i = 0; i < n; i++)
    {
        /* 68k word high byte = lower Z80 address (see shared_read_voice). */
        u16 w0 = shared_read16((u16)(Z80_ICS_OFF_LOG_DATA + i * 4));
        u16 w1 = shared_read16((u16)(Z80_ICS_OFF_LOG_DATA + i * 4 + 2));
        entries[i].seq = (u8)(w0 >> 8);
        entries[i].kind = (u8)w0;
        entries[i].a = (u8)(w1 >> 8);
        entries[i].b = (u8)w1;
    }
    z80_bus_release();
    if (count)
        *count = (u8)n;
    return true;
}

bool z80_ics_clear_irq_log(void)
{
    return command_simple(Z80_ICS_CMD_CLEAR_IRQ_LOG, 0, 0, 0, 0, NULL);
}

void z80_ics_peek(u16 offset, u8 *out, u16 len)
{
    z80_bus_take();
    for (u16 i = 0; i < len; i += 2)
    {
        u16 value = z80_read_word((u16)(offset + i));
        out[i] = (u8)(value >> 8);
        if ((u16)(i + 1) < len)
            out[i + 1] = (u8)value;
    }
    z80_bus_release();
}

bool z80_ics_read_status_port(u16 *result)
{
    if (!command_simple(Z80_ICS_CMD_READ_STATUS, 0, 0, 0, 0, NULL))
        return false;
    if (result)
    {
        z80_bus_take();
        *result = shared_read16(Z80_ICS_OFF_RESULT);
        z80_bus_release();
    }
    return true;
}

void set_osc_acc(z80_ics_voice_t *voice, u32 addr)
{
    voice->osc_acc_hi = (addr >> 4) & 0xffff;
    voice->osc_saddr = 0x40;
    voice->osc_acc_lo = (addr & 0xf) << 12;
}

static void set_loop_start(z80_ics_voice_t *voice, u32 addr)
{
    voice->osc_start_hi = (addr >> 4) & 0xffff;
    voice->osc_start_lo = (addr & 0xf) << 4;
}

static void set_loop_end(z80_ics_voice_t *voice, u32 addr)
{
    voice->osc_end_hi = (addr >> 4) & 0xffff;
    voice->osc_end_lo = (addr & 0xf) << 4;
}

static void make_bios_trace_voice(z80_ics_voice_t *voice)
{
    voice->osc_conf = 0x08;
    voice->osc_fc = 0x0155;
    voice->osc_start_hi = 0xb63a;
    voice->osc_start_lo = 0x60;
    voice->osc_end_hi = 0xb81e;
    voice->osc_end_lo = 0xb0;
    voice->vol_incr = 0x00;
    voice->vol_start = 0x00;
    voice->vol_end = 0x00;
    voice->vol_acc = 0xdff0;
    voice->osc_acc_hi = 0xb63a;
    voice->osc_acc_lo = 0x6000;
    voice->pan = 0x7f;
    voice->vol_ctrl = 0x00;
    voice->osc_ctl = 0x00;
    voice->osc_saddr = 0x40;
}

void z80_ics_make_sample_voice(u8 preset, z80_ics_voice_t *voice)
{
    for (u16 i = 0; i < sizeof(*voice); i++)
        ((u8 *)voice)[i] = 0;

    make_bios_trace_voice(voice);

    if (preset == 1)
    {
        /* Keep SAMPLE1 as the older custom looping sample for comparison. */
        voice->osc_conf = 0x08;
        voice->osc_fc = 12081;
        voice->vol_acc = 0xffff;
        voice->vol_start = 0xff;
        voice->vol_end = 0xff;
        voice->vol_ctrl = 0x00;
        set_loop_start(voice, 0x2d640);
        set_loop_end(voice, 0x3b2a0);
        set_osc_acc(voice, 0x2d640);
    }
}
