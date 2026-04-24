#include "../system.h"
#include "../memory_map.h"
#include "../page.h"

#include "../util.h"
#include "../tilemap.h"
#include "../igs023.h"
#include "../gui.h"
#include "../color.h"

static void sym_at(u16 code, u8 x, u8 y, u8 color)
{
    IGS023Tile *tile = &VRAM->bg[x + (y * 64)];
    tile->code = code;
    tile->color = color;
}

static void wobble(s16 offset)
{
    for (s16 y = 0; y < 64; y++)
    {
        VRAM->bg_scroll[y + 96 + 8] = sin_approx((y << 2) + offset) >> 2;
    }
}

static u8 sx, sy;
static u16 attrib = 0;
static IGS023Tile *tile;
static u8 zoom_index = 0;
static u16 zoom_table[32];
static bool animate = false;

static void init()
{
    igs023_init();
    text_reset();
    set_default_palette();
   
    //memset(VRAM->unused1, 0xffff, sizeof(VRAM->unused1));
    //memset(VRAM->unused2, 0xffff, sizeof(VRAM->unused2));

    memset(VRAM->bg, 0, sizeof(VRAM->bg));
    memset(VRAM->bg_scroll, 0, sizeof(VRAM->bg_scroll));
    
    //memset(PALRAM->unused, 0xffff, sizeof(PALRAM->unused));

    IGS023_BG_X_SET(8);
    IGS023_BG_Y_SET(8);

    memset(zoom_table, 0, sizeof(zoom_table));
    for (int i = 0; i < 32; i++)
    {
        IGS023_ZOOM[i] = zoom_table[i];
    }

    u16 codes[] =
    {
        0x7c4, 0x7c5, 0x7c6, 0x7c7, 0x7c8, 0x7c9, 0x7ca, 0x7cb,
        0x7cd, 0x7ce, 0x7cf, 0x7d0, 0x7d1, 0x7d2, 0x7d3, 0x7d4,
        0x7d5, 0x7d6, 0x7d7, 0x7d8, 0x7d9, 0x7da, 0x7db, 0x7dc,
    };

    int code = 0;
    for( u8 y = 0; y < 3; y++ )
    {
        for( u8 x = 0; x < 8; x++ )
        {
            sym_at(codes[code], x + 1, y + 3, 1);
            code++;
        }
    }

    u16 codes2[] =
    {
        0x4bc, 0x4bd, 0x4be, 0x4bf,
        0x4f3, 0x4f4, 0x4f5, 0x4e4
    };

    code = 0;
    for( u8 y = 0; y < 2; y++ )
    {
        for( u8 x = 0; x < 4; x++ )
        {
            sym_at(codes2[code], x + 9, y + 1, 1);
            code++;
        }
    }
    
    text_cursor(35, 3);
    text("* * * * * * * *");

    text_color(2);
    text_cursor(35, 10);
    text(" \e \e \e \e \e \e \e \e");
    text_cursor(35, 11);
    text("\e \e \e \e \e \e \e \e");

    tile = &VRAM->bg[1 + ( 3 * 64)];
}

static void update()
{
    igs023_wait_vblank();
    
    gui_begin(3, 1);
    gui_bits16_func("CTRL", IGS023_CTRL_GET, IGS023_CTRL_SET);
    gui_bits16_func("BG_CTRL", IGS023_BG_CTRL_GET, IGS023_BG_CTRL_SET);
    gui_u8("ZIDX", &zoom_index, 0, 0x1f);
    if (gui_bits16("ZOOM", &zoom_table[zoom_index])) IGS023_ZOOM[zoom_index] = zoom_table[zoom_index];
    gui_u16_func("X", IGS023_BG_X_GET, IGS023_BG_X_SET);
    gui_u16_func("Y", IGS023_BG_Y_GET, IGS023_BG_Y_SET);
    if (gui_u8("SX", &sx, 0, 0x1f)) IGS023_BG_CTRL_SET(( IGS023_BG_CTRL_GET() & 0xffe0 ) | ( sx & 0x1f ));
    if (gui_u8("SY", &sy, 0, 0x1f)) IGS023_BG_CTRL_SET(( IGS023_BG_CTRL_GET() & 0xfc1f ) | (( sy & 0x1f ) << 5));
    gui_toggle("ANIMATE", &animate);
    gui_end();

    if (animate) wobble(igs023_get_vblank_count());
}

PAGE_REGISTER(bg_test, init, update, NULL);

