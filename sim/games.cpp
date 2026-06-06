#include "games.h"
#include "sim_core.h"
#include "sim_sdram.h"
#include "sim_ddr.h"
#include "mra_loader.h"
#include "sim_hierarchy.h"
#include "PGM.h"
#include "PGM___024root.h"

#include "file_search.h"
#include <string.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace
{
struct PgmEntry
{
    uint32_t mapping = 0;
    uint32_t offset = 0;
    uint32_t size = 0;
};

constexpr size_t kPgmHeaderSize = 1024;
constexpr std::array<uint8_t, 6> kPgmMagic = {'I', 'G', 'S', 'P', 'G', 'M'};
constexpr uint8_t kPgmVersionMajor = 0x00;
constexpr uint8_t kPgmVersionMinor = 0x10;

uint32_t ReadLe32(const uint8_t *data)
{
    return (static_cast<uint32_t>(data[0]) << 0) | (static_cast<uint32_t>(data[1]) << 8) |
           (static_cast<uint32_t>(data[2]) << 16) | (static_cast<uint32_t>(data[3]) << 24);
}

bool EndsWithCaseInsensitive(const std::string &value, const std::string &suffix)
{
    if (value.size() < suffix.size())
        return false;

    return std::equal(suffix.rbegin(), suffix.rend(), value.rbegin(),
                      [](char a, char b) { return std::tolower(static_cast<unsigned char>(a)) == std::tolower(static_cast<unsigned char>(b)); });
}

std::string ReadPaddedString(const std::vector<uint8_t> &buffer, size_t offset, size_t size)
{
    if (offset >= buffer.size())
        return {};

    const size_t available = std::min(size, buffer.size() - offset);
    std::string value(reinterpret_cast<const char *>(buffer.data() + offset), available);
    const size_t nul = value.find('\0');
    if (nul != std::string::npos)
        value.resize(nul);
    return value;
}

void ClearCartConfig()
{
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0;
}

const char *RomDir()
{
    const char *romDir = std::getenv("PGM_ROM_DIR");
    return (romDir != nullptr && romDir[0] != '\0') ? romDir : "../roms";
}

std::string RomPath(const std::string &name)
{
    std::string path = RomDir();
    if (!path.empty() && path.back() != '/' && path.back() != '\\')
        path += '/';
    path += name;
    return path;
}

void AddRomZip(const std::string &name)
{
    gFileSearch.AddSearchPath(RomPath(name + ".zip"));
}

bool LoadBasePgmBios()
{
    AddRomZip("pgm");

    if (!gSimCore.mSDRAM->LoadData16be("pgm_p02s.u20", BIOS_PROG_ROM_SDR_BASE, 2))
        return false;
    if (!gSimCore.mSDRAM->LoadData("pgm_t01s.rom", BIOS_TILE_ROM_SDR_BASE, 1))
        return false;
    if (!gSimCore.mSDRAM->LoadData("pgm_m01s.rom", BIOS_MUSIC_ROM_SDR_BASE, 1))
        return false;

    return true;
}

bool LoadFileExact(const char *path, std::vector<uint8_t> &buffer)
{
    std::ifstream file(path, std::ios::binary);
    if (!file)
    {
        printf("Failed to open PGM file: %s\n", path);
        return false;
    }

    buffer.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    if (!file.good() && !file.eof())
    {
        printf("Failed to read PGM file: %s\n", path);
        return false;
    }

    return true;
}

bool ParsePgmEntry(const std::vector<uint8_t> &buffer, size_t offset, PgmEntry &entry)
{
    if (offset + 12 > buffer.size())
        return false;

    entry.mapping = ReadLe32(buffer.data() + offset + 0);
    entry.offset = ReadLe32(buffer.data() + offset + 4);
    entry.size = ReadLe32(buffer.data() + offset + 8);
    return true;
}

bool ValidatePgmEntry(const char *name, const PgmEntry &entry, size_t fileSize)
{
    if (entry.offset == 0 || entry.size == 0)
        return true;

    if (entry.offset > fileSize || entry.size > fileSize - entry.offset)
    {
        printf("Invalid %s entry: offset=0x%08X size=0x%08X file_size=0x%zx\n", name, entry.offset, entry.size, fileSize);
        return false;
    }

    return true;
}

bool LoadPgmEntry(const std::vector<uint8_t> &buffer, const char *name, const PgmEntry &entry, uint32_t destBase)
{
    if (entry.offset == 0 || entry.size == 0)
    {
        printf("Skipping %s (not present)\n", name);
        return true;
    }

    gSimCore.mSDRAM->Write(destBase, entry.size, buffer.data() + entry.offset);
    printf("Loaded %s: %u bytes from file offset 0x%08X to SDRAM 0x%08X (mapping 0x%08X)\n",
           name, entry.size, entry.offset, destBase, entry.mapping);
    return true;
}

bool LoadFileByNameOrCrc(const char *name, uint32_t crc, std::vector<uint8_t> &buffer)
{
    if (crc != 0 && gFileSearch.LoadFileByCRC(crc, buffer))
    {
        printf("Loaded file by CRC %08X for %s\n", crc, name);
        return true;
    }

    if (gFileSearch.LoadFile(name, buffer))
        return true;

    printf("Failed to find file: %s\n", name);
    return false;
}

bool LoadSdramData(const char *name, uint32_t crc, uint32_t destBase)
{
    std::vector<uint8_t> buffer;
    if (!LoadFileByNameOrCrc(name, crc, buffer))
        return false;

    gSimCore.mSDRAM->Write(destBase, static_cast<uint32_t>(buffer.size()), buffer.data());
    printf("Loaded %zu bytes from %s to SDRAM 0x%08X\n", buffer.size(), name, destBase);
    return true;
}

bool LoadSdramData16be(const char *name, uint32_t crc, uint32_t destBase, size_t fileOffset = 0, size_t length = 0)
{
    std::vector<uint8_t> buffer;
    if (!LoadFileByNameOrCrc(name, crc, buffer))
        return false;

    if (fileOffset > buffer.size())
    {
        printf("Invalid offset for %s: offset=0x%zx size=0x%zx\n", name, fileOffset, buffer.size());
        return false;
    }

    const size_t available = buffer.size() - fileOffset;
    if (length == 0)
        length = available;
    if (length > available)
    {
        printf("Invalid length for %s: offset=0x%zx length=0x%zx size=0x%zx\n", name, fileOffset, length, buffer.size());
        return false;
    }

    std::vector<uint8_t> swapped((length + 1) & ~size_t(1), 0);
    for (size_t i = 0; i < length; i += 2)
    {
        swapped[i + 0] = (i + 1 < length) ? buffer[fileOffset + i + 1] : 0;
        swapped[i + 1] = buffer[fileOffset + i + 0];
    }

    gSimCore.mSDRAM->Write(destBase, static_cast<uint32_t>(swapped.size()), swapped.data());
    printf("Loaded %zu bytes (16-bit BE) from %s offset 0x%zx to SDRAM 0x%08X\n", swapped.size(), name, fileOffset, destBase);
    return true;
}

bool LoadDdrData(const char *name, uint32_t crc, uint32_t destBase)
{
    std::vector<uint8_t> buffer;
    if (!LoadFileByNameOrCrc(name, crc, buffer))
        return false;

    if (!gSimCore.mDDRMemory->LoadData(buffer, destBase, 1))
        return false;

    printf("Loaded %zu bytes from %s to DDR 0x%08X\n", buffer.size(), name, destBase);
    return true;
}
}

static const char *gGameNames[N_GAMES] = {
    "pgm",
    "testbios",
    "pgm_test",
    "espgalbl",
    "orlegend",
    "ketbl",
    "ddpdojblkbl",
    "kovbl",
    "kovplusbl",
    "killbld",
    "drgw3",
    "kovsh",
    "photoy2k",
    "kov2",
};

static std::string gLoadedGameShortName = "unknown";

Game GameFind(const char *name)
{
    for (int i = 0; i < N_GAMES; i++)
    {
        if (!strcasecmp(name, gGameNames[i]))
        {
            return (Game)i;
        }
    }

    return GAME_INVALID;
}

const char *GameName(Game game)
{
    if (game == GAME_INVALID)
        return "INVALID";
    return gGameNames[game];
}

const char *GameLoadedShortName()
{
    return gLoadedGameShortName.c_str();
}

bool GameIsPgmFilePath(const char *name)
{
    return name != nullptr && EndsWithCaseInsensitive(name, ".pgm");
}

static void LoadPgm()
{
    LoadBasePgmBios();
    ClearCartConfig();
    gLoadedGameShortName = "pgm";
    gSimCore.SetGame(GAME_PGM);
}

static void LoadPgmTest()
{
    gFileSearch.AddSearchPath("../testroms/build/pgm_test/pgm/");
    AddRomZip("kov");
    AddRomZip("kovsh");
    LoadBasePgmBios();
    ClearCartConfig();
    gSimCore.mSDRAM->LoadData("pgm_b0600.u6", CART_B_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("pgm_b0601.u8", CART_B_ROM_SDR_BASE + 0x0800000, 1);
    gSimCore.mDDRMemory->LoadData("pgm_a0600.u1", CART_A_ROM_DDR_BASE, 1);
    gSimCore.mDDRMemory->LoadData("pgm_a0601.u3", CART_A_ROM_DDR_BASE + 0x0800000, 1);
    gSimCore.mDDRMemory->LoadData("pgm_a0602.u5", CART_A_ROM_DDR_BASE + 0x1000000, 1);
    gLoadedGameShortName = "pgm_test";
    gSimCore.SetGame(GAME_PGM_TEST);
}


static void LoadTestbios()
{
    AddRomZip("pgm");

    gSimCore.mSDRAM->LoadData16be("testbios.bin", BIOS_PROG_ROM_SDR_BASE, 2);
    gSimCore.mSDRAM->LoadData("pgm_t01s.rom", BIOS_TILE_ROM_SDR_BASE, 1);

    ClearCartConfig();
    gLoadedGameShortName = "testbios";
    gSimCore.SetGame(GAME_PGM);
}


static void LoadEspgalbl()
{
    LoadPgm();

    AddRomZip("espgalbl");
    AddRomZip("espgal");

    gSimCore.mSDRAM->LoadData16be("espgaluda_u8.bin", CART_PROG_ROM_SDR_BASE, 2);
    gSimCore.mSDRAM->LoadData("cave_t04801w064.u19", CART_TILE_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_b04801w064.u1", CART_B_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_w04801b032.u17", CART_MUSIC_ROM_SDR_BASE, 1);
    gSimCore.mDDRMemory->LoadData("cave_a04801w064.u7", CART_A_ROM_DDR_BASE, 1);
    gSimCore.mDDRMemory->LoadData("cave_a04802w064.u8", CART_A_ROM_DDR_BASE + 0x0800000, 1);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "espgalbl";
    gSimCore.SetGame(GAME_PGM);
}

static void LoadOrlegend()
{
    LoadPgm();

    AddRomZip("orlegend");

    LoadSdramData16be("p0103.rom", 0xd5e93543, CART_PROG_ROM_SDR_BASE);
    LoadSdramData("pgm_t0100.u8", 0x61425e1e, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a0100.u5", 0x8b3bd88a, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0101.u6", 0x3b9e9644, CART_A_ROM_DDR_BASE + 0x0400000);
    LoadDdrData("pgm_a0102.u7", 0x069e2c38, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a0103.u8", 0x4460a3fd, CART_A_ROM_DDR_BASE + 0x0c00000);
    LoadDdrData("pgm_a0104.u11", 0x5f8abb56, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadDdrData("pgm_a0105.u12", 0xa17a7147, CART_A_ROM_DDR_BASE + 0x1400000);
    LoadSdramData("pgm_b0100.u9", 0x69d2e48c, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b0101.u10", 0x0d587bf3, CART_B_ROM_SDR_BASE + 0x0400000);
    LoadSdramData("pgm_b0102.u15", 0x43823c1e, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m0100.u1", 0xe5c36c83, CART_MUSIC_ROM_SDR_BASE);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "orlegend";
    gSimCore.SetGame(GAME_PGM);
}

static void LoadKetbl()
{
    LoadPgm();

    AddRomZip("ketbl");
    AddRomZip("ket");

    LoadSdramData16be("ketsui_u1.bin", 0x391767b4, CART_PROG_ROM_SDR_BASE, 0x200000, 0x200000);
    LoadSdramData("t04701w064.u19", 0x2665b041, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("b04701w064.u1", 0x1bec008d, CART_B_ROM_SDR_BASE);
    LoadDdrData("a04701w064.u7", 0x5ef1b94b, CART_A_ROM_DDR_BASE);
    LoadDdrData("a04702w064.u8", 0x26d6da7f, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadSdramData("m04701b032.u17", 0xb46e22d1, CART_MUSIC_ROM_SDR_BASE);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "ketbl";
    gSimCore.SetGame(GAME_PGM);
}

static void LoadDdpdojblkbl()
{
    LoadPgm();

    AddRomZip("ddpdojblkbl");
    AddRomZip("ddpdojblk");
    AddRomZip("ddp3");

    LoadSdramData16be("ddp_doj_u1.bin", 0xeb4ab06a, CART_PROG_ROM_SDR_BASE);
    LoadSdramData("t04401w064.u19", 0x3a95f19c, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("b04401w064_corrupt.u1", 0x8cbff066, CART_B_ROM_SDR_BASE);
    LoadDdrData("a04401w064.u7", 0xed229794, CART_A_ROM_DDR_BASE);
    LoadDdrData("a04402w064.u8", 0x752167b0, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadSdramData("m04401b032.u17", 0x5a0dbd76, CART_MUSIC_ROM_SDR_BASE);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "ddpdojblkbl";
    gSimCore.SetGame(GAME_PGM);
}

static void LoadKovblCommon(const char *shortName, const char *zipName, uint32_t prg1Crc)
{
    LoadPgm();

    AddRomZip(zipName);
    AddRomZip("kov");
    AddRomZip("kovplus");

    LoadSdramData16be("prg1.29f1610ml", prg1Crc, CART_PROG_ROM_SDR_BASE);
    LoadSdramData16be("prg2.am27c4096", 0x7b3577dc, CART_PROG_ROM_SDR_BASE + 0x200000);
    LoadSdramData("t0600a 1610", 0x64e406a1, CART_TILE_ROM_SDR_BASE + 0x000000);
    LoadSdramData("t0600b 1610", 0x26591209, CART_TILE_ROM_SDR_BASE + 0x200000);
    LoadSdramData("t0600c 1610", 0x461dc80c, CART_TILE_ROM_SDR_BASE + 0x400000);
    LoadSdramData("t0600d 1610", 0xf7e6b529, CART_TILE_ROM_SDR_BASE + 0x600000);
    LoadSdramData("pgm_b0600.u5", 0x7d3cd059, CART_B_ROM_SDR_BASE + 0x000000);
    LoadSdramData("pgm_b0601.u7", 0xa0bb1c2f, CART_B_ROM_SDR_BASE + 0x800000);
    LoadDdrData("pgm_a0600.u2", 0xd8167834, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0601.u4", 0xff7a4373, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a0602.u6", 0xe7a32959, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadDdrData("pgm_a0603.u9", 0xec31abda, CART_A_ROM_DDR_BASE + 0x1800000);
    LoadSdramData("pgm_m0600.u3", 0x3ada4fd6, CART_MUSIC_ROM_SDR_BASE);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = shortName;
    gSimCore.SetGame(GAME_PGM);
}

static void LoadKovbl()
{
    LoadKovblCommon("kovbl", "kovbl", 0xe74fcc47);
}

static void LoadKovplusbl()
{
    LoadKovblCommon("kovplusbl", "kovplusbl", 0x35806d1b);
}

// Load the 64KB IGS022 protection data ROM into DDR (shared prot_cache).
// On real hardware this arrives via the rom_loader DDR path (LOAD_REGIONS
// index 8 -> PROT_ROM_DDR_BASE); the sim writes it to the DDR model directly.
static bool LoadIgs022ProtRom(const char *name, uint32_t crc)
{
    return LoadDdrData(name, crc, PROT_ROM_DDR_BASE);
}

static void LoadKillbld()
{
    LoadPgm();

    AddRomZip("killbld");

    // Encrypted 68000 program (decrypted in RTL).  Single WORD_SWAP ROM.
    LoadSdramData16be("p0300_v109.u9", 0x2fcee215, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t0300.u14", 0x0922f7d9, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a0300.u9", 0x3f9455d3, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0301.u10", 0x92776889, CART_A_ROM_DDR_BASE + 0x0400000);
    LoadDdrData("pgm_a0303.u11", 0x33f5cc69, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a0306.u12", 0xcc018a8e, CART_A_ROM_DDR_BASE + 0x0c00000);
    LoadDdrData("pgm_a0307.u2", 0xbc772e39, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadSdramData("pgm_b0300.u13", 0x7f876981, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b0302.u14", 0xeea9c502, CART_B_ROM_SDR_BASE + 0x0400000);
    LoadSdramData("pgm_b0303.u15", 0x77a9652e, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m0300.u1", 0x93159695, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs022ProtRom("kb_u2_v109.u2", 0xde3eae63);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "killbld";
    gSimCore.SetGame(GAME_KILLBLD);
}

static void LoadDrgw3()
{
    LoadPgm();

    AddRomZip("drgw3");

    // Encrypted 68000 program (decrypted in RTL).  Two LOAD16_BYTE ROMs:
    //   dw3_v106_u13.u13 -> even byte addresses (high byte of each 68k word)
    //   dw3_v106_u12.u12 -> odd  byte addresses (low  byte of each 68k word)
    // The CPU-facing word read = SDRAM[2k]<<8 | SDRAM[2k+1] (see prog_decrypt
    // comment in PGM.sv), so write even bytes from u13 and odd bytes from u12.
    {
        std::vector<uint8_t> uEven, uOdd;
        if (LoadFileByNameOrCrc("dw3_v106_u13.u13", 0x28284e22, uEven) &&
            LoadFileByNameOrCrc("dw3_v106_u12.u12", 0xc3f6838b, uOdd))
        {
            const size_t half = std::min(uEven.size(), uOdd.size());
            std::vector<uint8_t> prog(half * 2);
            for (size_t k = 0; k < half; k++)
            {
                prog[2 * k + 0] = uEven[k];
                prog[2 * k + 1] = uOdd[k];
            }
            gSimCore.mSDRAM->Write(CART_PROG_ROM_SDR_BASE,
                                   static_cast<uint32_t>(prog.size()), prog.data());
            printf("Loaded %zu bytes interleaved drgw3 program to SDRAM 0x%08X\n",
                   prog.size(), CART_PROG_ROM_SDR_BASE);
        }
    }

    LoadSdramData("pgm_t0400.u18", 0xb70f3357, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a0400.u9", 0xdd7bfd40, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0401.u10", 0xcab6557f, CART_A_ROM_DDR_BASE + 0x0400000);
    LoadSdramData("pgm_b0400.u13", 0x4bb87cc0, CART_B_ROM_SDR_BASE);
    LoadSdramData("pgm_m0400.u1", 0x031eb9ce, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs022ProtRom("dw3_text_u15.u15", 0x03dc4fdf);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "drgw3";
    gSimCore.SetGame(GAME_DRGW3);
}


// Load the 16KB IGS027A internal ARM ROM into DDR (shared prot_cache).
// On real hardware this arrives via the rom_loader DDR path (LOAD_REGIONS
// index 9 -> PROT_INT_ROM_DDR_BASE); raw bytes, little-endian as the ARM reads.
static bool LoadIgs027aIntRom(const char *name, uint32_t crc)
{
    return LoadDdrData(name, crc, PROT_INT_ROM_DDR_BASE);
}

static void LoadKovsh()
{
    LoadPgm();
    AddRomZip("kovsh");
    AddRomZip("kov");

    // 68000 program (not encrypted; protection is the ARM), WORD_SWAP.
    LoadSdramData16be("pgm_p0605_v104.u1", 0x7c78e5f3, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t0600.u11", 0x4acc1ad6, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a0600.u1", 0xd8167834, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0601.u3", 0xff7a4373, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a0602.u5", 0xe7a32959, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadDdrData("pgm_a0613.u7", 0xec31abda, CART_A_ROM_DDR_BASE + 0x1800000);
    LoadDdrData("pgm_a0604_v200.u9", 0x26b59fd3, CART_A_ROM_DDR_BASE + 0x1a00000);
    LoadSdramData("pgm_b0600.u6", 0x7d3cd059, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b0601.u8", 0xa0bb1c2f, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_b0602_v200.u10", 0x9df77934, CART_B_ROM_SDR_BASE + 0x0c00000);
    LoadSdramData("pgm_m0600.u4", 0x3ada4fd6, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("kovsh_v100_china.asic", 0x0f09a5c1);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "kovsh";
    gSimCore.SetGame(GAME_KOVSH);
}

static void LoadPhotoy2k()
{
    LoadPgm();
    AddRomZip("photoy2k");

    // 68000 program (encrypted; decrypted in RTL), WORD_SWAP, 2MB.
    LoadSdramData16be("pgm_p0701_v105.u2", 0xfab142e0, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t0700.u11", 0x93943b4d, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a0700.u2", 0x503c855b, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a0701.u4", 0x845e11a8, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a0702.u3", 0x42239e1b, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadSdramData("pgm_b0700.u7", 0x8cd027f6, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("photo_y2k_cg_v101_u6.u6", 0xda02ec3e, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m0700.u5", 0xacc7afce, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("igs027a_photoy2k_v100_china.asic", 0x1a0b68f6);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "photoy2k";
    gSimCore.SetGame(GAME_PHOTOY2K);
}

// pgm_kov2_decrypt (MAME pgmcrypt.cpp): the type2 external ARM ROM ("user1") is
// stored with an address-bit XOR (no table).  Applied at load; the runtime
// xor_table layer is applied in RTL by the igs027a wrapper at read time.
static void DecryptKov2ArmRom(std::vector<uint8_t> &buf)
{
    const size_t n = buf.size() / 2;
    for (size_t i = 0; i < n; i++)
    {
        uint16_t x = (uint16_t)buf[2 * i] | ((uint16_t)buf[2 * i + 1] << 8); // LE
        if ((i & 0x040080) != 0x000080) x ^= 0x0001; // IGS27_CRYPT1_ALT
        if ((i & 0x080030) == 0x080010) x ^= 0x0004; // IGS27_CRYPT3
        if ((i & 0x000042) != 0x000042) x ^= 0x0008; // IGS27_CRYPT4_ALT
        if ((i & 0x048100) == 0x048000) x ^= 0x0010; // IGS27_CRYPT5_ALT
        if ((i & 0x022004) != 0x000004) x ^= 0x0020; // IGS27_CRYPT6_ALT
        if ((i & 0x001800) != 0x000000) x ^= 0x0040; // IGS27_CRYPT7_ALT
        if ((i & 0x000820) == 0x000820) x ^= 0x0080; // IGS27_CRYPT8_ALT
        buf[2 * i]     = (uint8_t)(x & 0xff);
        buf[2 * i + 1] = (uint8_t)(x >> 8);
    }
}

static void LoadKov2()
{
    LoadPgm();
    AddRomZip("kov2");

    // 68000 program (plaintext, WORD_SWAP, 4MB).
    LoadSdramData16be("v107_u18.u18", 0x661a5b2c, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t1200.u27", 0xd7e26609, CART_TILE_ROM_SDR_BASE);
    LoadDdrData("pgm_a1200.u1", 0xceeb81d8, CART_A_ROM_DDR_BASE + 0x0000000);
    LoadDdrData("pgm_a1201.u4", 0x21063ca7, CART_A_ROM_DDR_BASE + 0x0800000);
    LoadDdrData("pgm_a1202.u6", 0x4bb92fae, CART_A_ROM_DDR_BASE + 0x1000000);
    LoadDdrData("pgm_a1203.u8", 0xe73cb627, CART_A_ROM_DDR_BASE + 0x1800000);
    LoadDdrData("pgm_a1204.u10", 0x14b4b5bb, CART_A_ROM_DDR_BASE + 0x2000000);
    LoadSdramData("pgm_b1200.u5", 0xbed7d994, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b1201.u7", 0xf251eb57, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m1200.u3", 0xb0d88720, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("kov2_v100_hongkong.asic", 0xe0d7679f);

    // External ARM ROM (2MB, encrypted): decrypt, then place in DDR.
    {
        std::vector<uint8_t> buf;
        if (LoadFileByNameOrCrc("v102_u19.u19", 0x462e2980, buf))
        {
            DecryptKov2ArmRom(buf);
            gSimCore.mDDRMemory->LoadData(buf, CART_ARM_ROM_DDR_BASE, 1);
            printf("Loaded %zu bytes (kov2-decrypted) ARM ROM to DDR 0x%08X\n",
                   buf.size(), CART_ARM_ROM_DDR_BASE);
        }
    }

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x800000;

    gLoadedGameShortName = "kov2";
    gSimCore.SetGame(GAME_KOV2);
}

bool GameInit(Game game)
{
    gFileSearch.ClearSearchPaths();
    gFileSearch.AddSearchPath(".");

    switch (game)
    {
    case GAME_PGM:
        LoadPgm();
        break;
    case GAME_TESTBIOS:
        LoadTestbios();
        break;
    case GAME_PGM_TEST:
        LoadPgmTest();
        break;
    case GAME_ESPGALBL:
        LoadEspgalbl();
        break;
    case GAME_ORLEGEND:
        LoadOrlegend();
        break;
    case GAME_KETBL:
        LoadKetbl();
        break;
    case GAME_DDPDOJBLKBL:
        LoadDdpdojblkbl();
        break;
    case GAME_KOVBL:
        LoadKovbl();
        break;
    case GAME_KOVPLUSBL:
        LoadKovplusbl();
        break;
    case GAME_KILLBLD:
        LoadKillbld();
        break;
    case GAME_DRGW3:
        LoadDrgw3();
        break;
    case GAME_KOVSH:
        LoadKovsh();
        break;
    case GAME_PHOTOY2K:
        LoadPhotoy2k();
        break;
    case GAME_KOV2:
        LoadKov2();
        break;
    default:
        return false;
    }

    return true;
}

bool GameInitPgmFile(const char *path)
{
    if (path == nullptr)
        return false;

    std::vector<uint8_t> buffer;
    if (!LoadFileExact(path, buffer))
        return false;

    if (buffer.size() < kPgmHeaderSize)
    {
        printf("Invalid PGM file '%s': too small (%zu bytes)\n", path, buffer.size());
        return false;
    }

    if (!std::equal(kPgmMagic.begin(), kPgmMagic.end(), buffer.begin()))
    {
        printf("Invalid PGM file '%s': bad magic\n", path);
        return false;
    }

    if (buffer[6] != kPgmVersionMajor || buffer[7] != kPgmVersionMinor)
    {
        printf("Invalid PGM file '%s': unsupported version %02X%02X\n", path, buffer[6], buffer[7]);
        return false;
    }

    const std::string shortName = ReadPaddedString(buffer, 24, 16);

    PgmEntry romP;
    PgmEntry romT;
    PgmEntry romM;
    PgmEntry romB;
    PgmEntry romA;
    if (!ParsePgmEntry(buffer, 512 + 0 * 12, romP) || !ParsePgmEntry(buffer, 512 + 1 * 12, romT) ||
        !ParsePgmEntry(buffer, 512 + 2 * 12, romM) || !ParsePgmEntry(buffer, 512 + 3 * 12, romB) ||
        !ParsePgmEntry(buffer, 512 + 4 * 12, romA))
    {
        printf("Invalid PGM file '%s': truncated header\n", path);
        return false;
    }

    if (!ValidatePgmEntry("romP", romP, buffer.size()) || !ValidatePgmEntry("romT", romT, buffer.size()) ||
        !ValidatePgmEntry("romM", romM, buffer.size()) || !ValidatePgmEntry("romB", romB, buffer.size()) ||
        !ValidatePgmEntry("romA", romA, buffer.size()))
    {
        return false;
    }

    gFileSearch.ClearSearchPaths();
    gFileSearch.AddSearchPath(".");
    if (!LoadBasePgmBios())
        return false;

    ClearCartConfig();
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;

    if (!LoadPgmEntry(buffer, "romP", romP, CART_PROG_ROM_SDR_BASE))
        return false;
    if (!LoadPgmEntry(buffer, "romT", romT, CART_TILE_ROM_SDR_BASE))
        return false;
    if (!LoadPgmEntry(buffer, "romM", romM, CART_MUSIC_ROM_SDR_BASE))
        return false;

    if (romP.offset != 0 && romP.size != 0)
        gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = romP.mapping;
    if (romT.offset != 0 && romT.size != 0)
        gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = romT.mapping;
    if (romM.offset != 0 && romM.size != 0)
        gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = romM.mapping;

    gLoadedGameShortName = shortName.empty() ? "pgm" : shortName;

    printf("Loaded PGM cart file: %s\n", path);
    gSimCore.SetGame(GAME_PGM);
    return true;
}

bool GameInitMra(const char *mraPath)
{
    gFileSearch.ClearSearchPaths();

    // Add common ROM search paths
    std::vector<std::string> searchPaths = {".", RomDir()};

    // Add ROM search paths
    for (const auto &path : searchPaths)
    {
        gFileSearch.AddSearchPath(path);
    }

    // Add the directory containing the MRA file as a search path
    std::string mraPathStr(mraPath);
    size_t lastSlash = mraPathStr.find_last_of("/\\");
    if (lastSlash != std::string::npos)
    {
        gFileSearch.AddSearchPath(mraPathStr.substr(0, lastSlash));
    }

    // Load the MRA file
    MRALoader loader;
    std::vector<uint8_t> romData;
    uint32_t address = 0;

    if (!loader.Load(mraPath, romData, address))
    {
        printf("Failed to load MRA file '%s': %s\n", mraPath, loader.GetLastError().c_str());
        return false;
    }

    printf("Loaded MRA: %s\n", mraPath);
    printf("ROM data size: %zu bytes\n", romData.size());

    if (address == 0)
    {
        if (!gSimCore.SendIOCTLData(0, romData))
        {
            printf("Failed to send ROM data via ioctl\n");
            return false;
        }
    }
    else
    {
        if (!gSimCore.SendIOCTLDataDDR(0, address, romData))
        {
            printf("Failed to send ROM data via DDR\n");
            return false;
        }
    }

    printf("Successfully loaded MRA: %s\n", mraPath);
    return true;
}
