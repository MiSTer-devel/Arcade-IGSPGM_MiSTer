#include <stdint.h>
#include <stdbool.h>

#include "printf/printf.h"
#include "debug_link.h"

typedef struct u8_rom
{
    uint8_t pad0;
    uint8_t v;
    uint8_t pad1;
    uint8_t pad2;
} u8_rom;

typedef volatile struct CommsRegisters
{
    uint8_t  magic[4];

    // only the least significant byte is relevant for these, using 32-bits to avoid potential atomic issues
    u8_rom   active;
    u8_rom   pending;
    u8_rom   in_seq;
    u8_rom   out_seq;
    uint32_t debug1;
    uint32_t debug2;

    uint8_t  reserved0[1024 - (7 * 4)];

    u8_rom   in_byte;
    uint8_t  reserved2[512 - (1 * 4)];

    uint16_t out_area[256];
} CommsRegisters;

_Static_assert(sizeof(CommsRegisters) == 2048, "CommsRegisters size mismatch");

CommsRegisters *comms_regs = (CommsRegisters *)(0x1f800 << 1);

// ---------------------------------------------------------------------------
// RAM FIFO transport (simulator only)
//
// The ROM mailbox above is the PicoROM hardware protocol: the host swaps
// single bytes into ROM and snoops reads.  The simulator cannot serve that
// protocol coherently because 68k ROM reads go through rom_cache, so it
// instead attaches to this WORK_RAM block: the target initializes the magic,
// the simulator scans WORK_RAM for it, sets sim_active, and both sides stream
// bytes through plain rings (WORK_RAM is uncached dual-port BRAM, so
// simulator-side writes are immediately visible).  Real hardware never
// touches this block, PicoROM cannot see WORK_RAM.
// ---------------------------------------------------------------------------

#define RAM_COMMS_BUF_SIZE 512
#define RAM_COMMS_MASK (RAM_COMMS_BUF_SIZE - 1)

typedef volatile struct RamComms
{
    uint8_t  magic[4];     // "RFIF", written last by ram_comms_init
    uint8_t  sim_active;   // simulator-owned: 1 while attached
    uint8_t  target_ready;
    uint16_t in_head;      // simulator-owned: host -> target bytes
    uint16_t in_tail;      // target-owned
    uint16_t out_head;     // target-owned: target -> host bytes
    uint16_t out_tail;     // simulator-owned
    uint8_t  in_buf[RAM_COMMS_BUF_SIZE];
    uint8_t  out_buf[RAM_COMMS_BUF_SIZE];
} RamComms;

__attribute__((section(".comms_buffer"))) __attribute__((used))
static RamComms ram_comms;

static bool magic_valid = false;
static bool comms_active = false;
static bool ram_comms_ready = false;
static bool use_ram_comms = false;

uint8_t comms_in_seq;
uint8_t comms_out_seq;
volatile uint16_t dummy_read;

static void ram_comms_init(void)
{
    if (ram_comms_ready)
        return;
    ram_comms.sim_active = 0;
    ram_comms.in_head = 0;
    ram_comms.in_tail = 0;
    ram_comms.out_head = 0;
    ram_comms.out_tail = 0;
    ram_comms.target_ready = 1;
    // magic last: the simulator scans for it and assumes the block is ready
    ram_comms.magic[0] = 'R';
    ram_comms.magic[1] = 'F';
    ram_comms.magic[2] = 'I';
    ram_comms.magic[3] = 'F';
    ram_comms_ready = true;
}

static bool comms_check_magic()
{
    if(!magic_valid)
    {
        if( comms_regs->magic[0] == 'I' && comms_regs->magic[1] == 'P' && comms_regs->magic[2] == 'O' && comms_regs->magic[3] == 'C' )
        {
            magic_valid = true;
        }
    }

    return magic_valid;
}

bool debug_link_check_active()
{
    ram_comms_init();
    if (ram_comms.sim_active == 1)
    {
        use_ram_comms = true;
        return true;
    }
    use_ram_comms = false;
    if( comms_regs->active.v == 1 ) return comms_check_magic();
    return false;
}


bool debug_link_update()
{
    bool active = debug_link_check_active();

    if (!comms_active && active)
    {
        comms_active = true;
        comms_in_seq = 0;
        comms_out_seq = 0;
    }
    else if (comms_active && !active)
    {
        comms_active = false;
    }

    return active;
}

void debug_link_status(char *str, int len)
{
    if (use_ram_comms)
    {
        snprintf(str, len, "RAM IN: %04X/%04X OUT: %04X/%04X", ram_comms.in_head, ram_comms.in_tail, ram_comms.out_head, ram_comms.out_tail);
        return;
    }
    snprintf(str, len, "ACT: %01X IN: %02X/%02X OUT: %02X/%02X %08X %08X", comms_regs->active.v, comms_regs->in_seq.v, comms_in_seq, comms_regs->out_seq.v, comms_out_seq, comms_regs->debug1, comms_regs->debug2);
}

int debug_link_read(void *buffer, int maxlen)
{
    if (!debug_link_update()) return 0;

    int len = 0;

    uint8_t *buffer8 = (uint8_t *)buffer;

    if (use_ram_comms)
    {
        uint16_t head = ram_comms.in_head;
        uint16_t tail = ram_comms.in_tail;
        while (tail != head && len < maxlen)
        {
            buffer8[len] = ram_comms.in_buf[tail & RAM_COMMS_MASK];
            tail++;
            len++;
        }
        ram_comms.in_tail = tail;
        return len;
    }

    while(comms_regs->active.v && ( (comms_in_seq != comms_regs->in_seq.v) || comms_regs->pending.v ))
    {
        if(comms_in_seq != comms_regs->in_seq.v)
        {
            buffer8[len] = comms_regs->in_byte.v;
            comms_in_seq++;
            len++;

            if (len == maxlen) return len;
        }
    }
    return len;
}

int debug_link_write(const void *data, int len)
{
    int sent = 0;

    if (!debug_link_update()) return 0;

    const uint8_t *data8 = (const uint8_t *)data;

    if (use_ram_comms)
    {
        while (sent < len)
        {
            uint16_t head = ram_comms.out_head;
            uint16_t tail = ram_comms.out_tail;
            if ((uint16_t)(head - tail) >= RAM_COMMS_BUF_SIZE)
            {
                // ring full: the simulator drains while it waits for the
                // response; bail out if it detached instead of spinning
                if (ram_comms.sim_active != 1)
                    break;
                continue;
            }
            ram_comms.out_buf[head & RAM_COMMS_MASK] = data8[sent];
            ram_comms.out_head = head + 1;
            sent++;
        }
        return sent;
    }

    while (sent < len)
    {
        const uint8_t b = data8[sent];
        dummy_read = comms_regs->out_area[b];
        comms_out_seq++;
        while (comms_regs->out_seq.v != comms_out_seq)
        {
            if( !comms_regs->active.v )
            {
                break;
            }
        };
        sent++;
    }

    return sent;
}
