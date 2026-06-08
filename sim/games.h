#ifndef GAMES_H
#define GAMES_H 1

#include <stdint.h>

enum Game : uint8_t
{
    GAME_PGM = 0,
    GAME_TESTBIOS,
    GAME_PGM_TEST,
    GAME_ESPGALBL,
    GAME_ORLEGEND,
    GAME_KETBL,
    GAME_DDPDOJBLKBL,
    GAME_KOVBL,
    GAME_KOVPLUSBL,
    GAME_KILLBLD,
    GAME_DRGW3,
    GAME_KOVSH,
    GAME_PHOTOY2K,
    GAME_KOV2,
    GAME_KOV2P,
    GAME_DDP2,
    GAME_MARTMAST,
    GAME_DW2001,
    GAME_DWPC,
    GAME_DMNFRNT,
    GAME_THEGLAD,

    N_GAMES,

    GAME_INVALID = 0xff
};

static const uint32_t BIOS_PROG_ROM_SDR_BASE   = 0x00000000;
static const uint32_t BIOS_TILE_ROM_SDR_BASE   = 0x00100000;
static const uint32_t BIOS_MUSIC_ROM_SDR_BASE  = 0x00300000;

static const uint32_t CART_PROG_ROM_SDR_BASE   = 0x00800000;
static const uint32_t CART_TILE_ROM_SDR_BASE   = 0x01000000;
static const uint32_t CART_MUSIC_ROM_SDR_BASE  = 0x02000000;
static const uint32_t CART_B_ROM_SDR_BASE      = 0x03000000;
static const uint32_t CART_A_ROM_SDR_BASE      = 0x04000000;  // sprite colour ROM (chip 1)
static const uint32_t CART_A_ROM_DDR_BASE      = 0x38000000;  // free DDR window (was A-ROM)
static const uint32_t CART_ARM_ROM_DDR_BASE    = 0x3C000000;  // type2/3 external ARM ROM
// Protection internal memories in DDR (shared prot_cache); must match system_consts.sv.
static const uint32_t PROT_INT_ROM_DDR_BASE    = 0x3C900000;  // igs027a 16KB internal ROM
static const uint32_t PROT_IRAM_DDR_BASE       = 0x3CA00000;  // igs027a 64KB internal RAM (P2)
static const uint32_t PROT_ROM_DDR_BASE        = 0x3CB00000;  // igs022 64KB private data ROM

Game GameFind(const char *name);
const char *GameName(Game game);
const char *GameLoadedShortName();
bool GameIsPgmFilePath(const char *name);

bool GameInit(Game game);
bool GameInitPgmFile(const char *path);
bool GameInitMra(const char *mraPath);

#endif // GAMES_H
