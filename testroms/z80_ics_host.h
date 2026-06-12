#if !defined(Z80_ICS_HOST_H)
#define Z80_ICS_HOST_H 1

#include <stdbool.h>
#include "system.h"
#include "z80_ics_protocol.h"

typedef struct
{
    u32 timer0;
    u32 timer1;
    u32 osc;
    u32 vol;
    u32 spurious;
} z80_ics_irq_counts_t;

typedef struct
{
    u8 seq;
    u8 kind; /* Z80_ICS_IRQ_LOG_KIND_* */
    u8 a;
    u8 b;
} z80_ics_irq_log_entry_t;

void z80_ics_init(void);
bool z80_ics_ready(void);
u16 z80_ics_last_error(void);
u16 z80_ics_last_status(void);
u8 z80_ics_last_seq(void);

bool z80_ics_ping(u16 *driver_magic);
bool z80_ics_read_reg(u8 voice, u8 reg, u8 width, u16 *result);
bool z80_ics_write_reg(u8 voice, u8 reg, u8 width, u16 value);
bool z80_ics_read_voice(u8 voice, z80_ics_voice_t *out);
bool z80_ics_write_voice(u8 voice, const z80_ics_voice_t *in);
bool z80_ics_get_irq_counts(z80_ics_irq_counts_t *out);
bool z80_ics_reset_irq_counts(z80_ics_irq_counts_t *out);
bool z80_ics_get_irq_log(z80_ics_irq_log_entry_t *entries, u8 *count);
bool z80_ics_clear_irq_log(void);
bool z80_ics_read_status_port(u16 *result);
/* Raw Z80-RAM read over the bus; no Z80 cooperation needed. */
void z80_ics_peek(u16 offset, u8 *out, u16 len);

void set_osc_acc(z80_ics_voice_t *voice, u32 addr);

void z80_ics_make_sample_voice(u8 preset, z80_ics_voice_t *voice);

#endif
