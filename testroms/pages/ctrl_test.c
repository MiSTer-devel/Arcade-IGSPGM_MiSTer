#include "../system.h"
#include "../memory_map.h"
#include "../page.h"

#include "../util.h"
#include "../tilemap.h"
#include "../igs023.h"
#include "../color.h"
#include "../gui.h"

static void sym_at(u16 code, u8 x, u8 y, u8 color)
{
    IGS023Tile *tile = &VRAM->bg[x + (y * 64)];
    tile->code = code;
    tile->attrib = 0;
    tile->color = color;
}

static void init()
{
    igs023_init();
    text_reset();
    set_default_palette();

    IGS023_BG_X_SET(8);
    IGS023_BG_Y_SET(8);

    for( int i = 0; i < 32; i++ )
        IGS023_ZOOM[i] = 0x5555;

    u16 codes[] =
    {
        0x7c4, 0x7c5, 0x7c6, 0x7c7, 0x7c8, 0x7c9, 0x7ca, 0x7cb,
        0x7cd, 0x7ce, 0x7cf, 0x7d0, 0x7d1, 0x7d2, 0x7d3, 0x7d4,
        0x7d5, 0x7d6, 0x7d7, 0x7d8, 0x7d9, 0x7da, 0x7db, 0x7dc,
    };
    
    memset(VRAM->bg, 0x0, sizeof(VRAM->bg));

    int code = 0;
    for( u8 y = 0; y < 3; y++ )
    {
        for( u8 x = 0; x < 8; x++ )
        {
            sym_at(codes[code], x + 1, y + 3, 1);
            sym_at(codes[code], x + 1, y + 16, 0);
            code++;
        }
    }
    
    memset(VRAM->bg_scroll, 0, sizeof(VRAM->bg_scroll));

    for( int x = 0; x < 0x400; x++)
        VRAM->bg_scroll[x] = -x;
}

static void update()
{
    u32 vblank_count = igs023_wait_vblank();

    text_color(1);
    text_cursor(3, 2);
    textf("VBL: %05X\n", vblank_count);

    IGS023Sprite *spr = SPRITE_BUFFER;

    IGS023_BG_Y_SET(vblank_count);
    spr->color = 0;
    spr->height = 89;
    spr->width = 10;
    spr->prio = 0;
    spr->xflip = 0;
    spr->yflip = 0;
    spr->xscale_mode = (vblank_count >> 7) & 0x1;
    spr->xscale_table = (vblank_count >> 3) & 0xf;
    spr->yscale_mode = (vblank_count >> 7) & 0x1;
    spr->yscale_table = (vblank_count >> 3) & 0xf;
    spr->address_lo = 0;
    spr->address_hi = 0;
    spr->xpos = 100;
    spr->ypos = 100;
    spr->unk1 = 0;
    spr->unk2 = 0;
    spr->unk3 = 0;
    spr++;

    spr->color = 0;
    spr->height = 89;
    spr->width = 10;
    spr->prio = 1;
    spr->xflip = 0;
    spr->yflip = 0;
    spr->xscale_mode = (vblank_count >> 7) & 0x1;
    spr->xscale_table = (vblank_count >> 3) & 0xf;
    spr->yscale_mode = (vblank_count >> 7) & 0x1;
    spr->yscale_table = (vblank_count >> 3) & 0xf;
    spr->address_lo = 0;
    spr->address_hi = 0;
    spr->xpos = 200;
    spr->ypos = 100;
    spr->unk1 = 0;
    spr->unk2 = 0;
    spr->unk3 = 0;
    spr++;

    spr->color = 0;
    spr->height = 89;
    spr->width = 10;
    spr->prio = 0;
    spr->xflip = 0;
    spr->yflip = 0;
    spr->xscale_mode = (vblank_count >> 7) & 0x1;
    spr->xscale_table = (vblank_count >> 3) & 0xf;
    spr->yscale_mode = (vblank_count >> 7) & 0x1;
    spr->yscale_table = (vblank_count >> 3) & 0xf;
    spr->address_lo = 0;
    spr->address_hi = 0;
    spr->xpos = 240;
    spr->ypos = 100;
    spr->unk1 = 0;
    spr->unk2 = 0;
    spr->unk3 = 0;
    spr++;


    spr->unk2 = 0;
    spr->width = 0;
    spr->height = 0;
    
    gui_begin(3, 4);
    gui_bits16_func("CTRL", IGS023_CTRL_GET, IGS023_CTRL_SET);
    gui_bits16_func("BG_CTRL", IGS023_BG_CTRL_GET, IGS023_BG_CTRL_SET);
    gui_bits16_func("UNK8", IGS023_UNK8_GET, IGS023_UNK8_SET);
    gui_bits16_func("UNK9", IGS023_UNK9_GET, IGS023_UNK9_SET);
    gui_bits16_func("UNKA", IGS023_UNKA_GET, IGS023_UNKA_SET);
    gui_bits16_func("UNKB", IGS023_UNKB_GET, IGS023_UNKB_SET);
    gui_bits16_func("UNKC", IGS023_UNKC_GET, IGS023_UNKC_SET);
    gui_bits16_func("UNKD", IGS023_UNKD_GET, IGS023_UNKD_SET);
    gui_bits16_func("UNKF", IGS023_UNKF_GET, IGS023_UNKF_SET);

    gui_end();
}

PAGE_REGISTER(ctrl_test, init, update, NULL);

