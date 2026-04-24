#include <stdint.h>
#include <stdarg.h>

#include "memory_map.h"
#include "printf/printf.h"
#include "tilemap.h"
#include "memory_map.h"
#include "util.h"
#include "igs023.h"

uint16_t cur_x, cur_y;
uint16_t cur_color;

static inline int width() { return 64; }

void text_color(int color)
{
    cur_color = color;
}

void text_cursor(int x, int y)
{
    cur_x = x;
    cur_y = y;
}

IGS023Tile *text_get_tile(int x, int y)
{
    uint16_t ofs = ( y * width() ) + x;
    return &VRAM->fg[ofs];
}

u16 text_get_x() { return cur_x; }
u16 text_get_y() { return cur_y; }

static uint16_t print_string(const char *str)
{
    uint16_t x = cur_x;
    uint16_t y = cur_y;

    uint16_t ofs = ( y * width() ) + x;

    uint16_t attr_color = cur_color & 0x1f;

    while(*str)
    {
        if( *str == '\n' )
        {
            y++;
            x = cur_x;
            ofs = (y * width()) + x;
        }
        else
        {
            VRAM->fg[ofs].color = attr_color;
            VRAM->fg[ofs].flipx = 0;
            VRAM->fg[ofs].flipy = 0;
            VRAM->fg[ofs].code = (*str) + 8;
            ofs++;
            x++;
        }
        str++;
    }
    uint16_t mx = x - cur_x;
    cur_x = x;
    cur_y = y;

    return mx;
}

uint16_t text(const char *txt)
{
    return print_string(txt);
}

uint16_t text_at(int x, int y, const char *txt)
{
    text_cursor(x, y);
    return print_string(txt);
}


uint16_t textf(const char *fmt, ...)
{
    char buf[128];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    buf[127] = '\0';
    va_end(args);
    
    return print_string(buf);
}

uint16_t textf_at(int x, int y, const char *fmt, ...)
{
    char buf[128];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    buf[127] = '\0';
    va_end(args);
    
    text_cursor(x, y);
    return print_string(buf);
}

void text_clear(int x, int y, int w, int h)
{
    IGS023Tile *ptr = &VRAM->fg[(y * width()) + x];
    for (int yy = 0; yy < h; yy++)
    {
        memset(ptr, 0, w * 4);
        ptr += width();
    }
}

void text_reset()
{
    memset(VRAM->fg, 0, sizeof(VRAM->fg));

    IGS023_FG_X_SET(0);
    IGS023_FG_Y_SET(0);
}

