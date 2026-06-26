#include "../system.h"
#include "../memory_map.h"
#include "../page.h"

#include "../util.h"
#include "../tilemap.h"
#include "../igs023.h"
#include "../color.h"
#include "../gui.h"

static uint16_t frame_count = 0;
static uint16_t zoom[2];

static void block_at(u8 x, u8 y, u8 color)
{
    IGS023Tile *tile = text_get_tile(x, y);
    tile->code = 0x20;
    tile->color = color;
}

static void init()
{
    igs023_init();
    text_reset();
    set_default_palette();
 
    frame_count = 0;
}

typedef struct
{
    u32 address;
    u16 width;
    u16 height;
} SpriteDef;

static const SpriteDef box_trans_16x16  = { 0x00837530,  16, 16 };
static const SpriteDef box_opaque_16x16 = { 0x00837200,  16, 16 };
static const SpriteDef box_trans_32x8  = { 0x00837530,  32, 8 };
static const SpriteDef box_opaque_32x8 = { 0x00837200,  32, 8 };
static const SpriteDef box_opaque_32x16 = { 0x00837178,  32, 16 };
static const SpriteDef drop_shadow_16   = { 0x0083b330,  16, 9  };
static const SpriteDef drop_shadow_32   = { 0x0083b34a,  32, 11 };
static const SpriteDef drop_shadow_48   = { 0x0083b37e,  48, 13 };
static const SpriteDef drop_shadow_64   = { 0x0083b3d4,  64, 13 };
static const SpriteDef drop_shadow_80   = { 0x0083b444,  80, 13 };
static const SpriteDef drop_shadow_96   = { 0x0083b4ce,  96, 13 };
static const SpriteDef oval_80          = { 0x00a25226,  80, 17 };
static const SpriteDef dude_128         = { 0x0053b52e, 128, 90 };
static const SpriteDef knight_240       = { 0x00533c5c, 240, 123 };

void SpriteEndMarker(u8 idx)
{
    IGS023Sprite *spr = &SPRITE_BUFFER[idx];
    spr->unk2 = 0;
    spr->width = 0;
    spr->height = 0;
}

static u8 sprite_x_scale = 0x10;
static u8 sprite_y_scale = 0x10;
static bool sprite_y_flip = false;
static bool sprite_x_flip = false;

static bool first_frame = true;

void SpriteSimple(u8 idx, const SpriteDef *def, u8 color, s16 x, s16 y)
{
    IGS023Sprite *spr = &SPRITE_BUFFER[idx];
    memset(spr, 0, sizeof(IGS023Sprite));

    spr->height = def->height;
    spr->width = def->width >> 4;
    spr->address_lo = def->address >> 1;
    spr->address_hi = (def->address >> 17);
    spr->xscale_mode = sprite_x_scale >> 4;
    spr->yscale_mode = sprite_y_scale >> 4;
    spr->xscale_table = sprite_x_scale & 0xf;
    spr->yscale_table = sprite_y_scale & 0xf;
    spr->xpos = x;
    spr->ypos = y;
    spr->color = color;
    spr->yflip = sprite_y_flip;
    spr->xflip = sprite_x_flip;
}

static u8 mode = 4;
static u8 count = 1;
static u16 sprite_y = 0;
static u16 sprite_x = 120;

static void update()
{
    IGS023_CTRL_OR(IGS023_CTRL_DMA);

    u32 vblank_count = igs023_wait_vblank();

    text_color(1);
    text_cursor(3, 2);
    textf("VBL: %05X  FRAME: %05X\n", vblank_count, frame_count);

    block_at(20, 0, 2);

    gui_begin(3, 4);
    bool changed = gui_u8("MODE", &mode, 0, 6);
    changed |= gui_u8("COUNT", &count, 1, 255);
    changed |= gui_toggle("FLIP Y", &sprite_y_flip);
    changed |= gui_toggle("FLIP X", &sprite_x_flip);
    changed |= gui_u8("SX", &sprite_x_scale, 0, 31);
    changed |= gui_u8("SY", &sprite_y_scale, 0, 31);
    changed |= gui_u16("X", &sprite_x);
    changed |= gui_u16("Y", &sprite_y);
    gui_end();

    if (changed || frame_count == 0)
    {
        switch(mode)
        {
            case 0:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &box_opaque_16x16, 2 + (i % 2), sprite_x + (i * 2), sprite_y);
                }
                SpriteEndMarker(count);
                break;

            case 1:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &drop_shadow_96, i % 2, sprite_x + (i * 2), sprite_y);
                }
                SpriteEndMarker(count);
                break;

            case 2:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &box_trans_16x16, i % 2, sprite_x + (i * 2), sprite_y);
                }
                SpriteSimple(count - 1, &box_opaque_16x16, 0, (count - 1) * 2, sprite_y);
                SpriteEndMarker(count);
                break;

            case 3:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &box_trans_32x8, i % 2, sprite_x + (i * 8), sprite_y);
                }
                SpriteSimple(count - 1, &box_opaque_32x8, 0, (count - 1) * 2, sprite_y);
                SpriteEndMarker(count);
                break;

            case 4:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &knight_240, 0, sprite_x + (i * 8), sprite_y);
                }
                SpriteEndMarker(count);
                break;

            case 5:
                for( int i = 0; i < count; i++ )
                {
                    SpriteSimple(i, &dude_128, 0, sprite_x + (i * 8), sprite_y);
                }
                SpriteEndMarker(count);
                break;



            default:
                SpriteEndMarker(0);
                break;
        }
    }

    frame_count++;
}

PAGE_REGISTER(sprite_test, init, update, NULL);

