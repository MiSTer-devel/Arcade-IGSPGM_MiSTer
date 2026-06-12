#include <stddef.h>

#include "../system.h"
#include "../page.h"
#include "../tilemap.h"
#include "../igs023.h"
#include "../color.h"
#include "../debug_link.h"
#include "../z80_ics_host.h"
#include "../ics_remote_protocol.h"
#include "../util.h"

#define RX_BUF_SIZE 384
#define TX_BUF_SIZE 160

static u8 rx_buf[RX_BUF_SIZE];
static u16 rx_len;
static u32 frame_count;
static u16 command_count;
static u16 error_count;
static u8 last_cmd;
static u8 last_status_code;
static u16 driver_magic;

static u16 get_be16(const u8 *p)
{
    return ((u16)p[0] << 8) | p[1];
}

static void put_be16(u8 *p, u16 v)
{
    p[0] = (u8)(v >> 8);
    p[1] = (u8)v;
}

static void put_be32(u8 *p, u32 v)
{
    p[0] = (u8)(v >> 24);
    p[1] = (u8)(v >> 16);
    p[2] = (u8)(v >> 8);
    p[3] = (u8)v;
}

static void send_response(u8 seq, u8 status, const u8 *payload, u8 payload_len)
{
    u8 tx[TX_BUF_SIZE];
    u16 total = ICS_REMOTE_HEADER_SIZE + payload_len;
    if (total > TX_BUF_SIZE)
    {
        payload_len = TX_BUF_SIZE - ICS_REMOTE_HEADER_SIZE;
        total = TX_BUF_SIZE;
    }

    tx[0] = ICS_REMOTE_RSP_MAGIC0;
    tx[1] = ICS_REMOTE_RSP_MAGIC1;
    tx[2] = ICS_REMOTE_VERSION;
    tx[3] = seq;
    tx[4] = status;
    tx[5] = payload_len;
    if (payload_len && payload)
        memcpy(tx + ICS_REMOTE_HEADER_SIZE, payload, payload_len);

    debug_link_write(tx, total);
    last_status_code = status;
    if (status == ICS_REMOTE_STATUS_OK)
        command_count++;
    else
        error_count++;
}

static void send_ics_error(u8 seq)
{
    u8 payload[4];
    put_be16(payload + 0, z80_ics_last_status());
    put_be16(payload + 2, z80_ics_last_error());
    send_response(seq, ICS_REMOTE_STATUS_ICS_ERROR, payload, sizeof(payload));
}

static void handle_ping(u8 seq)
{
    u8 payload[7];
    u16 magic = 0;
    if (!z80_ics_ping(&magic))
    {
        send_ics_error(seq);
        return;
    }
    driver_magic = magic;
    put_be16(payload + 0, magic);
    put_be16(payload + 2, z80_ics_last_status());
    put_be16(payload + 4, z80_ics_last_error());
    payload[6] = z80_ics_last_seq();
    send_response(seq, ICS_REMOTE_STATUS_OK, payload, sizeof(payload));
}

static void handle_init(u8 seq)
{
    z80_ics_init();
    handle_ping(seq);
}

static void handle_read_reg(u8 seq, const u8 *payload, u8 len)
{
    u16 result = 0;
    if (len != 3)
    {
        send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        return;
    }
    if (!z80_ics_read_reg(payload[0], payload[1], payload[2], &result))
    {
        send_ics_error(seq);
        return;
    }
    u8 out[2];
    put_be16(out, result);
    send_response(seq, ICS_REMOTE_STATUS_OK, out, sizeof(out));
}

static void handle_write_reg(u8 seq, const u8 *payload, u8 len)
{
    if (len != 5)
    {
        send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        return;
    }
    if (!z80_ics_write_reg(payload[0], payload[1], payload[2], get_be16(payload + 3)))
    {
        send_ics_error(seq);
        return;
    }
    send_response(seq, ICS_REMOTE_STATUS_OK, NULL, 0);
}

static void handle_read_voice(u8 seq, const u8 *payload, u8 len)
{
    u8 voice_bytes[Z80_ICS_VOICE_SIZE];
    if (len != 1)
    {
        send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        return;
    }
    memset(voice_bytes, 0, sizeof(voice_bytes));
    if (!z80_ics_read_voice(payload[0], (z80_ics_voice_t *)voice_bytes))
    {
        send_ics_error(seq);
        return;
    }
    send_response(seq, ICS_REMOTE_STATUS_OK, voice_bytes, Z80_ICS_VOICE_SIZE);
}

static void handle_write_voice(u8 seq, const u8 *payload, u8 len)
{
    u8 voice_bytes[Z80_ICS_VOICE_SIZE];
    if (len != 1 + Z80_ICS_VOICE_SIZE)
    {
        send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        return;
    }
    memcpy(voice_bytes, payload + 1, Z80_ICS_VOICE_SIZE);
    if (!z80_ics_write_voice(payload[0], (const z80_ics_voice_t *)voice_bytes))
    {
        send_ics_error(seq);
        return;
    }
    send_response(seq, ICS_REMOTE_STATUS_OK, NULL, 0);
}

static void put_irq_counts(u8 *out, const z80_ics_irq_counts_t *counts)
{
    put_be32(out + 0, counts->timer0);
    put_be32(out + 4, counts->timer1);
    put_be32(out + 8, counts->osc);
    put_be32(out + 12, counts->vol);
    put_be32(out + 16, counts->spurious);
}

static void handle_get_irq_counts(u8 seq, u8 reset)
{
    z80_ics_irq_counts_t counts;
    u8 out[20];
    bool ok = reset ? z80_ics_reset_irq_counts(&counts) : z80_ics_get_irq_counts(&counts);
    if (!ok)
    {
        send_ics_error(seq);
        return;
    }
    put_irq_counts(out, &counts);
    send_response(seq, ICS_REMOTE_STATUS_OK, out, sizeof(out));
}

static void handle_get_irq_counts_timed(u8 seq, u8 reset)
{
    z80_ics_irq_counts_t counts;
    u8 out[24];
    bool ok = reset ? z80_ics_reset_irq_counts(&counts) : z80_ics_get_irq_counts(&counts);
    if (!ok)
    {
        send_ics_error(seq);
        return;
    }
    /* IRQ6-driven vblank count, NOT the page-loop frame counter: the loop
       misses vblanks whenever a command (e.g. a Z80 bus-arbitrated voice
       read) runs past 16 ms, but the level-6 handler always increments.
       Sampled right after the Z80 counts read so the two stay paired. */
    put_be32(out, igs023_get_vblank_count());
    put_irq_counts(out + 4, &counts);
    send_response(seq, ICS_REMOTE_STATUS_OK, out, sizeof(out));
}

static void handle_get_irq_log(u8 seq, u8 clear)
{
    z80_ics_irq_log_entry_t entries[Z80_ICS_IRQ_LOG_MAX];
    u8 out[1 + Z80_ICS_IRQ_LOG_MAX * Z80_ICS_IRQ_LOG_ENTRY_SIZE];
    u8 count = 0;
    if (!z80_ics_get_irq_log(entries, &count))
    {
        send_ics_error(seq);
        return;
    }
    if (clear && !z80_ics_clear_irq_log())
    {
        send_ics_error(seq);
        return;
    }
    out[0] = count;
    for (u8 i = 0; i < count; i++)
    {
        out[1 + i * 4 + 0] = entries[i].seq;
        out[1 + i * 4 + 1] = entries[i].kind;
        out[1 + i * 4 + 2] = entries[i].a;
        out[1 + i * 4 + 3] = entries[i].b;
    }
    send_response(seq, ICS_REMOTE_STATUS_OK, out, (u8)(1 + count * 4));
}

static void handle_request(const u8 *req)
{
    u8 seq = req[3];
    u8 cmd = req[4];
    u8 len = req[5];
    const u8 *payload = req + ICS_REMOTE_HEADER_SIZE;

    last_cmd = cmd;

    if (req[2] != ICS_REMOTE_VERSION)
    {
        send_response(seq, ICS_REMOTE_STATUS_BAD_VERSION, NULL, 0);
        return;
    }

    switch (cmd)
    {
    case ICS_REMOTE_CMD_PING:
        if (len == 0) handle_ping(seq); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_INIT:
        if (len == 0) handle_init(seq); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_READ_REG:
        handle_read_reg(seq, payload, len);
        break;
    case ICS_REMOTE_CMD_WRITE_REG:
        handle_write_reg(seq, payload, len);
        break;
    case ICS_REMOTE_CMD_READ_VOICE:
        handle_read_voice(seq, payload, len);
        break;
    case ICS_REMOTE_CMD_WRITE_VOICE:
        handle_write_voice(seq, payload, len);
        break;
    case ICS_REMOTE_CMD_GET_IRQ_COUNTS:
        if (len == 0) handle_get_irq_counts(seq, 0); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_RESET_IRQ_COUNTS:
        if (len == 0) handle_get_irq_counts(seq, 1); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_GET_IRQ_COUNTS_TIMED:
        if (len == 1) handle_get_irq_counts_timed(seq, payload[0]); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_GET_IRQ_LOG:
        if (len == 1) handle_get_irq_log(seq, payload[0]); else send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0);
        break;
    case ICS_REMOTE_CMD_PEEK_Z80:
    {
        u8 out[64];
        u16 addr;
        if (len != 3 || payload[2] > 64) { send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0); break; }
        addr = ((u16)payload[0] << 8) | payload[1];
        z80_ics_peek(addr, out, payload[2]);
        send_response(seq, ICS_REMOTE_STATUS_OK, out, payload[2]);
        break;
    }
    case ICS_REMOTE_CMD_READ_STATUS:
    {
        u16 status = 0;
        u8 out[2];
        if (len != 0) { send_response(seq, ICS_REMOTE_STATUS_BAD_LENGTH, NULL, 0); break; }
        if (!z80_ics_read_status_port(&status)) { send_ics_error(seq); break; }
        put_be16(out, status);
        send_response(seq, ICS_REMOTE_STATUS_OK, out, sizeof(out));
        break;
    }
    default:
        send_response(seq, ICS_REMOTE_STATUS_BAD_CMD, NULL, 0);
        break;
    }
}

static void drop_rx(u16 count)
{
    if (count >= rx_len)
    {
        rx_len = 0;
        return;
    }
    for (u16 i = 0; i < rx_len - count; i++)
        rx_buf[i] = rx_buf[i + count];
    rx_len -= count;
}

static void process_rx(void)
{
    while (rx_len >= ICS_REMOTE_HEADER_SIZE)
    {
        if (rx_buf[0] != ICS_REMOTE_REQ_MAGIC0 || rx_buf[1] != ICS_REMOTE_REQ_MAGIC1)
        {
            drop_rx(1);
            error_count++;
            continue;
        }

        u16 total = ICS_REMOTE_HEADER_SIZE + rx_buf[5];
        if (total > RX_BUF_SIZE)
        {
            drop_rx(1);
            error_count++;
            continue;
        }
        if (rx_len < total)
            return;

        handle_request(rx_buf);
        drop_rx(total);
    }
}

static void poll_debug_link(void)
{
    if (!debug_link_check_active())
    {
        rx_len = 0;
        return;
    }

    if (rx_len < RX_BUF_SIZE)
    {
        int got = debug_link_read(rx_buf + rx_len, RX_BUF_SIZE - rx_len);
        if (got > 0)
            rx_len += (u16)got;
    }
    process_rx();
}

static const char *status_name(u8 status)
{
    switch (status)
    {
    case ICS_REMOTE_STATUS_OK: return "OK";
    case ICS_REMOTE_STATUS_BAD_MAGIC: return "MAGIC";
    case ICS_REMOTE_STATUS_BAD_VERSION: return "VER";
    case ICS_REMOTE_STATUS_BAD_LENGTH: return "LEN";
    case ICS_REMOTE_STATUS_BAD_CMD: return "CMD";
    case ICS_REMOTE_STATUS_ICS_ERROR: return "ICS";
    default: return "UNK";
    }
}

static void init(void)
{
    igs023_init();
    text_reset();
    set_default_palette();
    IGS023_BG_CTRL_SET(0xffff);
    IGS023_FG_X_SET(8);
    IGS023_FG_Y_SET(8);

    rx_len = 0;
    frame_count = 0;
    command_count = 0;
    error_count = 0;
    last_cmd = 0;
    last_status_code = 0;
    driver_magic = 0;

    z80_ics_init();
    z80_ics_ping(&driver_magic);
}

static void update(void)
{
    igs023_wait_vblank();
    frame_count++;
    poll_debug_link();

    text_color(1);
    text_cursor(2, 2);
    text("ICS REMOTE\n");
    textf("LINK %s RX %04X\n", debug_link_check_active() ? "ACTIVE" : "INACTIVE", rx_len);
    textf("DRV %04X RDY %04X SEQ %02X\n", driver_magic, z80_ics_ready(), z80_ics_last_seq());
    textf("CMD %02X STAT %s OK %04X ERR %04X\n", last_cmd, status_name(last_status_code), command_count, error_count);
    textf("ZSTAT %04X ZERR %04X\n", z80_ics_last_status(), z80_ics_last_error());
    textf("FRAME %05X VBL %05X\n", (u16)frame_count, (u16)igs023_get_vblank_count());
}

PAGE_REGISTER(ics_remote, init, update, NULL);
