package system_consts;
    parameter int SSIDX_GLOBAL = 0;
    parameter int SSIDX_WORK_RAM = 1;
    parameter int SSIDX_VIDEO_RAM = 2;
    parameter int SSIDX_PAL_RAM = 3;
    parameter int SSIDX_IGS023 = 4;
    parameter int SSIDX_Z80_RAM = 5;
    parameter int SSIDX_Z80 = 6;
    parameter int SSIDX_IGS026_X = 7;
    parameter int SSIDX_ICS2115 = 8;
    parameter int SSIDX_ASIC3 = 9;
    parameter int SSIDX_IGS025 = 10;
    parameter int SSIDX_IGS022 = 11;          // engine regs[]/stack[]/stack_ptr
    parameter int SSIDX_IGS022_RAM_LO = 12;   // shared protection RAM, low bytes
    parameter int SSIDX_IGS022_RAM_HI = 13;   // shared protection RAM, high bytes

    parameter bit [31:0] SS_DDR_BASE         = 32'h3E00_0000;
    parameter bit [31:0] CART_A_ROM_DDR_BASE = 32'h3800_0000;
    parameter bit [31:0] DOWNLOAD_DDR_BASE   = 32'h3000_0000;
    parameter bit [31:0] CART_ARM_ROM_DDR_BASE = 32'h3C00_0000;
    parameter bit [31:0] PROT_INT_ROM_DDR_BASE = 32'h3C90_0000; // igs027a 16KB internal ROM
    parameter bit [31:0] PROT_IRAM_DDR_BASE    = 32'h3CA0_0000; // igs027a 64KB internal RAM (P2)
    parameter bit [31:0] PROT_ROM_DDR_BASE     = 32'h3CB0_0000; // igs022 64KB private data ROM

    /*
    
    BIOS
    - PROG - 1M 
    - TILE - 2M
    - MUSIC - 2M

    CART
    - PROG - 16M
    - TILE - 32M
    - MUSIC - 32M
    - B - 16M
    - A - 64M
    */

    parameter bit [31:0] BIOS_PROG_ROM_SDR_BASE   = 32'h0000_0000;
    parameter bit [31:0] BIOS_TILE_ROM_SDR_BASE   = 32'h0010_0000;
    parameter bit [31:0] BIOS_MUSIC_ROM_SDR_BASE  = 32'h0030_0000;

    parameter bit [31:0] CART_PROG_ROM_SDR_BASE   = 32'h0100_0000;
    parameter bit [31:0] CART_TILE_ROM_SDR_BASE   = 32'h0200_0000;
    parameter bit [31:0] CART_MUSIC_ROM_SDR_BASE  = 32'h0400_0000;
    parameter bit [31:0] CART_B_ROM_SDR_BASE      = 32'h0600_0000;

    typedef enum bit [3:0] {
        STORAGE_SDR,
        STORAGE_DDR,
        STORAGE_BLOCK
    } region_storage_t;

    typedef enum bit [3:0] {
        ENCODING_NORMAL,
        ENCODING_SWAP16
    } region_encoding_t;

    typedef struct packed {
        bit [31:0] base_addr;
        region_storage_t storage;
        region_encoding_t encoding;
        bit [3:0]  base_idx;
    } region_t;

    parameter region_t REGION_BIOS_PROG_ROM      = '{ base_addr:BIOS_PROG_ROM_SDR_BASE,      storage:STORAGE_SDR,   encoding:ENCODING_SWAP16, base_idx:0 };
    parameter region_t REGION_BIOS_TILE_ROM      = '{ base_addr:BIOS_TILE_ROM_SDR_BASE,      storage:STORAGE_SDR,   encoding:ENCODING_NORMAL, base_idx:0 };
    parameter region_t REGION_BIOS_MUSIC_ROM     = '{ base_addr:BIOS_MUSIC_ROM_SDR_BASE,     storage:STORAGE_SDR,   encoding:ENCODING_NORMAL, base_idx:0  };
    parameter region_t REGION_CART_PROG_ROM      = '{ base_addr:CART_PROG_ROM_SDR_BASE,      storage:STORAGE_SDR,   encoding:ENCODING_SWAP16, base_idx:1  };
    parameter region_t REGION_CART_TILE_ROM      = '{ base_addr:CART_TILE_ROM_SDR_BASE,      storage:STORAGE_SDR,   encoding:ENCODING_NORMAL, base_idx:2  };
    parameter region_t REGION_CART_MUSIC_ROM     = '{ base_addr:CART_MUSIC_ROM_SDR_BASE,     storage:STORAGE_SDR,   encoding:ENCODING_NORMAL, base_idx:3  };
    parameter region_t REGION_CART_A_ROM         = '{ base_addr:CART_A_ROM_DDR_BASE,         storage:STORAGE_DDR,   encoding:ENCODING_NORMAL, base_idx:0  };
    parameter region_t REGION_CART_B_ROM         = '{ base_addr:CART_B_ROM_SDR_BASE,         storage:STORAGE_SDR,   encoding:ENCODING_NORMAL, base_idx:0  };
    parameter region_t REGION_IGS022_ROM         = '{ base_addr:PROT_ROM_DDR_BASE,           storage:STORAGE_DDR,   encoding:ENCODING_NORMAL, base_idx:8  };
    parameter region_t REGION_IGS027_IROM        = '{ base_addr:PROT_INT_ROM_DDR_BASE,       storage:STORAGE_DDR,   encoding:ENCODING_NORMAL, base_idx:9  };

    parameter region_t LOAD_REGIONS[10] = '{
        REGION_BIOS_PROG_ROM,
        REGION_BIOS_TILE_ROM,
        REGION_BIOS_MUSIC_ROM,
        REGION_CART_PROG_ROM,
        REGION_CART_TILE_ROM,
        REGION_CART_MUSIC_ROM,
        REGION_CART_A_ROM,
        REGION_CART_B_ROM,
        REGION_IGS022_ROM,
        REGION_IGS027_IROM
    };

    // Values MUST match the C++ `Game` enum in sim/games.h (board_cfg = game << 8).
    typedef enum bit [7:0] {
        GAME_PGM      = 8'd0,
        GAME_KILLBLD  = 8'd9,
        GAME_DRGW3    = 8'd10,
        GAME_KOVSH    = 8'd11,
        GAME_PHOTOY2K = 8'd12,
        GAME_KOV2     = 8'd13
    } game_t;

    typedef struct packed {
        game_t    game;
        bit [7:0] unused;
    } board_cfg_t;

    typedef struct packed
    {
        bit [23:0] words;
        bit [1:0]  sub;
    } arom_offset_t;

endpackage


