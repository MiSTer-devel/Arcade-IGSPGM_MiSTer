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

    // BIOS 68k program: NORMAL byte order (raw).  PGM program ROMs are WORD_SWAP
    // so a little-endian SDRAM read yields the 68k word; no load-time swap.
    if (!gSimCore.mSDRAM->LoadData("pgm_p02s.u20", BIOS_PROG_ROM_SDR_BASE, 1))
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

bool LoadPgmEntry(const std::vector<uint8_t> &buffer, const char *name, const PgmEntry &entry, uint32_t destBase,
                  bool swap16 = false)
{
    if (entry.offset == 0 || entry.size == 0)
    {
        printf("Skipping %s (not present)\n", name);
        return true;
    }

    if (swap16)
    {
        // 68k program: SDRAM holds the word little-endian (read = SDRAM[2k+1]<<8
        // | SDRAM[2k]); the .pgm payload stores 68k big-endian words, so swap.
        std::vector<uint8_t> prog((entry.size + 1) & ~uint32_t(1), 0);
        for (uint32_t i = 0; i < entry.size; i += 2)
        {
            prog[i + 0] = (i + 1 < entry.size) ? buffer[entry.offset + i + 1] : 0;
            prog[i + 1] = buffer[entry.offset + i + 0];
        }
        gSimCore.mSDRAM->Write(destBase, static_cast<uint32_t>(prog.size()), prog.data());
    }
    else
    {
        gSimCore.mSDRAM->Write(destBase, entry.size, buffer.data() + entry.offset);
    }
    printf("Loaded %s: %u bytes from file offset 0x%08X to SDRAM 0x%08X (mapping 0x%08X)%s\n",
           name, entry.size, entry.offset, destBase, entry.mapping, swap16 ? " [swap16]" : "");
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

// ---- load-time decryption (mirrors RTL) ----------------------------------
// Static ROM decryption is applied at LOAD time (not in the CPU read paths).
// These C++ routines MUST stay byte-for-byte identical to their RTL twins:
//   Decrypt68kProg   <-> rtl/rom_decrypt.sv   (68k cart program, region 3)
//   DecryptArmExrom  <-> rtl/exrom_decrypt.sv (ARM external ROM, region 10)
// The byte-for-byte parity check (load_game vs load_mra) guards against drift.
//
// SDRAM is little-endian in the model (SimSDRAM read = mData[a+1]<<8 | mData[a]),
// so a 16-bit word lives as {lo=buf[2k], hi=buf[2k+1]}; DDR lanes are LE too.

const uint8_t KOVSH_TAB[256] = {
    0xe7, 0x06, 0xa3, 0x70, 0xf2, 0x58, 0xe6, 0x59, 0xe4, 0xcf, 0xc2, 0x79, 0x1d, 0xe3, 0x71, 0x0e,
    0xb6, 0x90, 0x9a, 0x2a, 0x8c, 0x41, 0xf7, 0x82, 0x9b, 0xef, 0x99, 0x0c, 0xfa, 0x2f, 0xf1, 0xfe,
    0x8f, 0x70, 0xf4, 0xc1, 0xb5, 0x3d, 0x7c, 0x60, 0x4c, 0x09, 0xf4, 0x2e, 0x7c, 0x87, 0x63, 0x5f,
    0xce, 0x99, 0x84, 0x95, 0x06, 0x9a, 0x20, 0x23, 0x5a, 0xb9, 0x52, 0x95, 0x48, 0x2c, 0x84, 0x60,
    0x69, 0xe3, 0x93, 0x49, 0xb9, 0xd6, 0xbb, 0xd6, 0x9e, 0xdc, 0x96, 0x12, 0xfa, 0x60, 0xda, 0x5f,
    0x55, 0x5d, 0x5b, 0x20, 0x07, 0x1e, 0x97, 0x42, 0x77, 0xea, 0x1d, 0xe0, 0x70, 0xfb, 0x6a, 0x00,
    0x77, 0x9a, 0xef, 0x1b, 0xe0, 0xf9, 0x0d, 0xc1, 0x2e, 0x2f, 0xef, 0x25, 0x29, 0xe5, 0xd8, 0x2c,
    0xaf, 0x01, 0xd9, 0x6c, 0x31, 0xce, 0x5c, 0xea, 0xab, 0x1c, 0x92, 0x16, 0x61, 0xbc, 0xe4, 0x7c,
    0x5a, 0x76, 0xe9, 0x92, 0x39, 0x5b, 0x97, 0x60, 0xea, 0x57, 0x83, 0x9c, 0x92, 0x29, 0xa7, 0x12,
    0xa9, 0x71, 0x7a, 0xf9, 0x07, 0x68, 0xa7, 0x45, 0x88, 0x10, 0x81, 0x12, 0x2c, 0x67, 0x4d, 0x55,
    0x33, 0xf0, 0xfa, 0xd7, 0x1d, 0x4d, 0x0e, 0x63, 0x03, 0x34, 0x65, 0xe2, 0x76, 0x0f, 0x98, 0xa9,
    0x5f, 0x9a, 0xd3, 0xca, 0xdd, 0xc1, 0x5b, 0x3d, 0x4d, 0xf8, 0x40, 0x08, 0xdc, 0x05, 0x38, 0x00,
    0xcb, 0x24, 0x02, 0xff, 0x39, 0xe2, 0x9e, 0x04, 0x9a, 0x08, 0x63, 0xc8, 0x2b, 0x5a, 0x34, 0x06,
    0x62, 0xc1, 0xbb, 0x8a, 0xd0, 0x54, 0x4c, 0x43, 0x21, 0x4e, 0x4c, 0x99, 0x80, 0xc2, 0x3d, 0xce,
    0x2a, 0x7b, 0x09, 0x62, 0x1a, 0x91, 0x9b, 0xc3, 0x41, 0x24, 0xa0, 0xfd, 0xb5, 0x67, 0x93, 0x07,
    0xa7, 0xb8, 0x85, 0x8a, 0xa1, 0x1e, 0x4f, 0xb6, 0x75, 0x38, 0x65, 0x8a, 0xf9, 0x7c, 0x00, 0xa0,
};

const uint8_t PHOTOY2K_TAB[256] = {
    0xd9, 0x92, 0xb2, 0xbc, 0xa5, 0x88, 0xe3, 0x48, 0x7d, 0xeb, 0xc5, 0x4d, 0x31, 0xe4, 0x82, 0xbc,
    0x82, 0xcf, 0xe7, 0xf3, 0x15, 0xde, 0x8f, 0x91, 0xef, 0xc6, 0xb8, 0x81, 0x97, 0xe3, 0xdf, 0x4d,
    0x88, 0xbf, 0xe4, 0x05, 0x25, 0x73, 0x1e, 0xd0, 0xcf, 0x1e, 0xeb, 0x4d, 0x18, 0x4e, 0x6f, 0x9f,
    0x00, 0x72, 0xc3, 0x74, 0xbe, 0x02, 0x09, 0x0a, 0xb0, 0xb1, 0x8e, 0x9b, 0x08, 0xed, 0x68, 0x6d,
    0x25, 0xe8, 0x28, 0x94, 0xa6, 0x44, 0xa6, 0xfa, 0x95, 0x69, 0x72, 0xd3, 0x6d, 0xb6, 0xff, 0xf3,
    0x45, 0x4e, 0xa3, 0x60, 0xf2, 0x58, 0xe7, 0x59, 0xe4, 0x4f, 0x70, 0xd2, 0xdd, 0xc0, 0x6e, 0xf3,
    0xd7, 0xb2, 0xdc, 0x1e, 0xa8, 0x41, 0x07, 0x5d, 0x60, 0x15, 0xea, 0xcf, 0xdb, 0xc1, 0x1d, 0x4d,
    0xb7, 0x42, 0xec, 0xc4, 0xca, 0xa9, 0x40, 0x30, 0x0f, 0x3c, 0xe2, 0x81, 0xe0, 0x5c, 0x51, 0x07,
    0xb0, 0x1e, 0x4a, 0xb3, 0x64, 0x3e, 0x1c, 0x62, 0x17, 0xcd, 0xf2, 0xe4, 0x14, 0x9d, 0xa6, 0xd4,
    0x64, 0x36, 0xa5, 0xe8, 0x7e, 0x84, 0x0e, 0xb3, 0x5d, 0x79, 0x57, 0xea, 0xd7, 0xad, 0xbc, 0x9e,
    0x2d, 0x90, 0x03, 0x9e, 0x0e, 0xc6, 0x98, 0xdb, 0xe3, 0xb6, 0x9f, 0x9b, 0xf6, 0x21, 0xe6, 0x98,
    0x94, 0x77, 0xb7, 0x2b, 0xaa, 0xc9, 0xff, 0xef, 0x7a, 0xf2, 0x71, 0x4e, 0x52, 0x06, 0x85, 0x37,
    0x81, 0x8e, 0x86, 0x64, 0x39, 0x92, 0x2a, 0xca, 0xf3, 0x3e, 0x87, 0xb5, 0x0c, 0x7b, 0x42, 0x5e,
    0x04, 0xa7, 0xfb, 0xd7, 0x13, 0x7f, 0x83, 0x6a, 0x77, 0x0f, 0xa7, 0x34, 0x51, 0x88, 0x9c, 0xac,
    0x23, 0x90, 0x4d, 0x4d, 0x72, 0x4e, 0xa3, 0x26, 0x1a, 0x45, 0x61, 0x0e, 0x10, 0x24, 0x8a, 0x27,
    0x92, 0x14, 0x23, 0xae, 0x4b, 0x80, 0xae, 0x6a, 0x56, 0x01, 0xac, 0x55, 0xf7, 0x6d, 0x9b, 0x6d,
};

const uint8_t PUZZLI2_TAB[256] = {
    0xb7, 0x66, 0xa3, 0xc0, 0x51, 0x55, 0x6d, 0x63, 0x86, 0x60, 0x64, 0x6c, 0x67, 0x18, 0x0b, 0x05,
    0x62, 0xff, 0xe0, 0x1e, 0x30, 0x21, 0x2e, 0x40, 0x41, 0xb9, 0x60, 0x38, 0xd1, 0x24, 0x7e, 0x36,
    0x7a, 0x0b, 0x1c, 0x69, 0x4f, 0x09, 0xe1, 0x9e, 0xcf, 0xcd, 0x7c, 0x00, 0x73, 0x08, 0x77, 0x37,
    0x5f, 0x50, 0x32, 0x3e, 0xd3, 0x54, 0x77, 0x6b, 0x60, 0x60, 0x74, 0x7c, 0x55, 0x4f, 0x44, 0x5e,
    0x66, 0x5c, 0x58, 0x26, 0x35, 0x29, 0x3f, 0x35, 0x3f, 0x1c, 0x0b, 0x0d, 0x08, 0x5b, 0x59, 0x5c,
    0xa0, 0xa5, 0x87, 0x85, 0x24, 0x75, 0x5f, 0x42, 0x1b, 0xf3, 0x1a, 0x58, 0x17, 0x58, 0x71, 0x6b,
    0x69, 0x89, 0x7d, 0x3a, 0xf3, 0xc4, 0x5d, 0xa0, 0x4f, 0x27, 0x58, 0xc4, 0xa8, 0xdd, 0xa8, 0xfb,
    0xbe, 0xa4, 0xe2, 0xee, 0x07, 0x10, 0x90, 0x72, 0x99, 0x08, 0x68, 0x6d, 0x5c, 0x5c, 0x6d, 0x58,
    0x2f, 0xdc, 0x15, 0xd5, 0xd6, 0xd6, 0x3b, 0x3b, 0xf9, 0x32, 0xcc, 0xdd, 0xd4, 0xf1, 0xea, 0xed,
    0xe4, 0xf6, 0xf2, 0x91, 0xca, 0xc1, 0xed, 0xf2, 0xf6, 0xfb, 0xc0, 0xe8, 0xe3, 0xe7, 0xfa, 0xf1,
    0xf5, 0x08, 0x26, 0x2b, 0x2f, 0x34, 0x39, 0x13, 0x28, 0x07, 0x88, 0x5b, 0x8f, 0x94, 0x9b, 0x2e,
    0xf5, 0xab, 0x72, 0x76, 0x7a, 0x40, 0xb9, 0x09, 0xd8, 0x3b, 0xcd, 0x31, 0x3d, 0x42, 0xab, 0xb1,
    0xb5, 0xb9, 0x3b, 0xe3, 0x0b, 0x65, 0x18, 0xfb, 0x1f, 0x12, 0xe4, 0xe8, 0xec, 0xf2, 0xf7, 0xfc,
    0xc0, 0xe8, 0xe0, 0xe6, 0xfa, 0xf1, 0xf4, 0x0b, 0x26, 0x2b, 0x30, 0x35, 0x39, 0x13, 0x29, 0x21,
    0x0c, 0x11, 0x16, 0x1b, 0x1f, 0x64, 0x0e, 0x60, 0x05, 0x79, 0x7c, 0x37, 0x00, 0x0f, 0x4f, 0x38,
    0x1d, 0x18, 0xa2, 0xb6, 0xb2, 0xa9, 0xac, 0xab, 0xae, 0x91, 0x98, 0x8d, 0x91, 0xbb, 0xb1, 0xc0,
};

// CAVE type1 (recreated internal ROM) 68k decrypt tables (MAME pgmcrypt.cpp).
const uint8_t KET_TAB[256] = {
    0x49, 0x47, 0x53, 0x30, 0x30, 0x30, 0x34, 0x52, 0x44, 0x31, 0x30, 0x32, 0x31, 0x30, 0x31, 0x35,
    0x7c, 0x49, 0x27, 0xa5, 0xff, 0xf6, 0x98, 0x2d, 0x0f, 0x3d, 0x12, 0x23, 0xe2, 0x30, 0x50, 0xcf,
    0xf1, 0x82, 0xf0, 0xce, 0x48, 0x44, 0x5b, 0xf3, 0x0d, 0xdf, 0xf8, 0x5d, 0x50, 0x53, 0x91, 0xd9,
    0x12, 0xaf, 0x05, 0x7a, 0x98, 0xd0, 0x2f, 0x76, 0xf1, 0x5d, 0x17, 0x44, 0xc5, 0x03, 0x58, 0xf4,
    0x61, 0xee, 0xd1, 0xce, 0x00, 0x88, 0x90, 0x2e, 0x5c, 0x76, 0xfb, 0x9f, 0x75, 0xcf, 0x40, 0x37,
    0xa1, 0x9f, 0x00, 0x32, 0xd5, 0x9c, 0x37, 0xd2, 0x32, 0x27, 0x6f, 0x76, 0xd3, 0x86, 0x25, 0xf9,
    0xd6, 0x60, 0x7b, 0x4e, 0xa9, 0x7a, 0x20, 0x59, 0x96, 0xb1, 0x7d, 0x10, 0x92, 0x37, 0x22, 0xd2,
    0x42, 0x12, 0x6f, 0x07, 0x4f, 0xd2, 0x87, 0xfa, 0xeb, 0x92, 0x71, 0xf3, 0xa4, 0x31, 0x91, 0x98,
    0x68, 0xd2, 0x47, 0x86, 0xda, 0x92, 0xe5, 0x2b, 0xd4, 0x89, 0xd7, 0xe7, 0x3d, 0x03, 0x0d, 0x63,
    0x0c, 0x00, 0xac, 0x31, 0x9d, 0xe9, 0xf6, 0xa5, 0x34, 0x95, 0x77, 0xf2, 0xcf, 0x7c, 0x72, 0x89,
    0x31, 0x3a, 0x8b, 0xae, 0x2b, 0x47, 0xb6, 0x5d, 0x2d, 0xf5, 0x5f, 0x5c, 0x0e, 0xab, 0xdb, 0xa1,
    0x18, 0x60, 0x0e, 0xe6, 0x58, 0x5b, 0x5e, 0x8b, 0x24, 0x29, 0xd8, 0xac, 0xed, 0xdf, 0xa2, 0x83,
    0x46, 0x91, 0xa1, 0xff, 0x35, 0x13, 0x6a, 0xa5, 0xba, 0xef, 0x6e, 0xa8, 0x9e, 0xa6, 0x62, 0x44,
    0x7e, 0x2c, 0xed, 0x60, 0x17, 0x9e, 0x96, 0x64, 0xd3, 0x46, 0xec, 0x58, 0x95, 0xd1, 0xf7, 0x3e,
    0xc2, 0xcf, 0xdf, 0xb0, 0x90, 0x6c, 0xdb, 0xbe, 0x93, 0x6d, 0x5d, 0x02, 0x85, 0x6e, 0x7c, 0x05,
    0x55, 0x5a, 0xa1, 0xd7, 0x73, 0x2b, 0x76, 0xe9, 0x5b, 0xe4, 0x0c, 0x2e, 0x60, 0xcb, 0x4b, 0x72,
};

const uint8_t ESPGAL_TAB[256] = {
    0x49, 0x47, 0x53, 0x30, 0x30, 0x30, 0x37, 0x52, 0x44, 0x31, 0x30, 0x33, 0x30, 0x39, 0x30, 0x39,
    0xa7, 0xf1, 0x0a, 0xca, 0x69, 0xb2, 0xce, 0x86, 0xec, 0x3d, 0xa2, 0x5a, 0x03, 0xe9, 0xbf, 0xba,
    0xf7, 0xd5, 0xec, 0x68, 0x03, 0x90, 0x15, 0xcc, 0x0d, 0x08, 0x2d, 0x76, 0xa5, 0xb5, 0x41, 0xf1,
    0x43, 0x06, 0xdd, 0xcb, 0xbd, 0x0c, 0xa4, 0xe2, 0x08, 0x65, 0x2a, 0xf0, 0x30, 0x6b, 0x15, 0x59,
    0x99, 0x9e, 0x75, 0x35, 0x77, 0x4f, 0x60, 0x99, 0x8c, 0x8f, 0xd2, 0x2b, 0x21, 0x57, 0xc3, 0xe5,
    0x48, 0xf9, 0x8a, 0x29, 0x50, 0xc6, 0x71, 0x06, 0x89, 0x01, 0x9a, 0xc9, 0x39, 0x04, 0x12, 0xc8,
    0xdf, 0xb1, 0x33, 0x6b, 0xa7, 0x1c, 0x3f, 0x7b, 0x2d, 0x76, 0x3a, 0xaf, 0x76, 0x3d, 0x08, 0x74,
    0x2c, 0xa2, 0xc8, 0xfd, 0x1a, 0x3a, 0x6f, 0x8b, 0xe8, 0xe9, 0xa9, 0xfe, 0x17, 0x0c, 0xed, 0x9d,
    0x40, 0xe6, 0xdf, 0x22, 0x89, 0x4d, 0xea, 0x09, 0x68, 0x96, 0x1e, 0x1a, 0x9c, 0xbd, 0x47, 0x35,
    0x68, 0xd9, 0x4f, 0x5e, 0x12, 0xbf, 0xd6, 0x09, 0x9d, 0xf6, 0x0f, 0xa7, 0xc2, 0xdb, 0xde, 0x70,
    0x35, 0x15, 0x2f, 0x73, 0x16, 0x3c, 0x9a, 0xdc, 0xb5, 0xc5, 0x35, 0x86, 0x8a, 0x31, 0xb8, 0xc1,
    0x74, 0x76, 0xd7, 0x65, 0x32, 0xad, 0xdc, 0x17, 0x1f, 0xfe, 0x85, 0xda, 0x32, 0xc9, 0x1d, 0xda,
    0x36, 0x16, 0xde, 0x76, 0x45, 0x3f, 0x85, 0x8c, 0x8b, 0xdc, 0x37, 0x08, 0x39, 0xef, 0x94, 0xaf,
    0xc8, 0x51, 0x19, 0x29, 0x70, 0x5d, 0xbb, 0x4e, 0xe8, 0xdb, 0xc2, 0xb2, 0x5f, 0x2e, 0xe3, 0x73,
    0xba, 0xc2, 0xa1, 0x42, 0x10, 0xb0, 0xe5, 0xb0, 0x64, 0xb4, 0xdc, 0xbb, 0xa1, 0x51, 0x12, 0x98,
    0xdc, 0x43, 0xcc, 0xc3, 0xc5, 0x25, 0xab, 0x45, 0x6e, 0x63, 0x7e, 0x45, 0x40, 0x63, 0x67, 0xd2,
};

const uint8_t PY2K2_TAB[256] = {
    0x74, 0xe8, 0xa8, 0x64, 0x26, 0x44, 0xa6, 0x9a, 0xa5, 0x69, 0xa2, 0xd3, 0x6d, 0xba, 0xff, 0xf3,
    0xeb, 0x6e, 0xe3, 0x70, 0x72, 0x58, 0x27, 0xd9, 0xe4, 0x9f, 0x50, 0xa2, 0xdd, 0xce, 0x6e, 0xf6,
    0x44, 0x72, 0x0c, 0x7e, 0x4d, 0x41, 0x77, 0x2d, 0x00, 0xad, 0x1a, 0x5f, 0x6b, 0xc0, 0x1d, 0x4e,
    0x4c, 0x72, 0x62, 0x3c, 0x32, 0x28, 0x43, 0xf8, 0x9d, 0x52, 0x05, 0x7e, 0xd1, 0xee, 0x82, 0x61,
    0x3b, 0x3f, 0x77, 0xf3, 0x8f, 0x7e, 0x3f, 0xf1, 0xdf, 0x8f, 0x68, 0x43, 0xd7, 0x68, 0xdf, 0x19,
    0x87, 0xff, 0x74, 0xe5, 0x3f, 0x43, 0x8e, 0x80, 0x0f, 0x7e, 0xdb, 0x32, 0xe8, 0xd1, 0x66, 0x8f,
    0xbe, 0xe2, 0x33, 0x94, 0xc8, 0x32, 0x39, 0xfa, 0xf0, 0x43, 0xde, 0x84, 0x18, 0xd0, 0x6d, 0xd5,
    0x74, 0x98, 0xf8, 0x64, 0xcf, 0x84, 0xc6, 0xea, 0x55, 0x32, 0xe2, 0x38, 0xdd, 0xea, 0xfd, 0x6c,
    0xeb, 0x6e, 0xe3, 0x70, 0xae, 0x38, 0xc7, 0xd9, 0x54, 0x84, 0x10, 0xc1, 0xfd, 0x1e, 0x6e, 0x6d,
    0x37, 0xe0, 0x03, 0x9e, 0x06, 0x36, 0x68, 0x5b, 0xe3, 0xf6, 0x7f, 0x0b, 0x56, 0x79, 0xe0, 0xa8,
    0x98, 0x77, 0xc7, 0x2b, 0xa5, 0x79, 0xff, 0x2f, 0xca, 0x15, 0x71, 0x7e, 0x02, 0xbf, 0x87, 0xb7,
    0x7a, 0x8e, 0xe6, 0x64, 0x32, 0x62, 0x2a, 0xca, 0x23, 0x72, 0x87, 0xb5, 0x0c, 0x02, 0x4b, 0xee,
    0x44, 0x72, 0x9c, 0x7e, 0x5d, 0xc1, 0xa7, 0x1d, 0x30, 0x38, 0xda, 0xc9, 0x5b, 0xd0, 0x11, 0xf9,
    0xb1, 0x72, 0x6c, 0x04, 0x31, 0xc9, 0x50, 0x60, 0x6f, 0xc1, 0xf2, 0xae, 0x00, 0xf4, 0x5d, 0x66,
    0x43, 0x0e, 0x7a, 0xc3, 0x76, 0xae, 0x3c, 0xc2, 0xb7, 0xc9, 0x52, 0xf4, 0x74, 0x51, 0xaf, 0x12,
    0x19, 0xc6, 0x75, 0xe8, 0x6c, 0x54, 0x7e, 0x63, 0xdd, 0xae, 0x07, 0x5a, 0xb7, 0x00, 0xb5, 0x5e,
};

// 68k cart program XOR (must match rtl/rom_decrypt.sv).  `wordBase` is the
// 16-bit word index of buf[0] within the cart program region (almost always 0).
void Decrypt68kProg(Game game, std::vector<uint8_t> &buf, uint32_t wordBase = 0)
{
    const size_t n = buf.size() / 2;
    for (size_t k = 0; k < n; k++)
    {
        const uint32_t i = wordBase + static_cast<uint32_t>(k); // region word index
        const uint32_t word_addr = 0x080000u + i;               // matches rom_decrypt.sv
        uint16_t x = 0;
        switch (game)
        {
        case GAME_KILLBLD:
            if (word_addr < 0x180000u)
            {
                if (((i & 0x006d00u) == 0x000400u) || ((i & 0x006c80u) == 0x000880u)) x ^= 0x0008;
                if (((i & 0x007500u) == 0x002400u) || ((i & 0x007600u) == 0x003200u)) x ^= 0x1000;
            }
            break;
        case GAME_DRGW3:
            if (word_addr < 0x100000u)
            {
                if (((i & 0x005460u) == 0x001400u) || ((i & 0x005450u) == 0x001040u)) x ^= 0x0100;
                if (((i & 0x005e00u) == 0x001c00u) || ((i & 0x005580u) == 0x001100u)) x ^= 0x0040;
            }
            break;
        case GAME_KOVSH:
            if (word_addr < 0x280000u)
            {
                if ((i & 0x040080u) != 0x000080u)                            x ^= 0x0001;
                if (((i & 0x004008u) == 0x004008u) && ((i & 0x180000u) != 0)) x ^= 0x0002;
                if ((i & 0x000030u) == 0x000010u)                            x ^= 0x0004;
                if ((i & 0x000242u) != 0x000042u)                            x ^= 0x0008;
                if ((i & 0x008100u) == 0x008000u)                            x ^= 0x0010;
                if ((i & 0x002004u) != 0x000004u)                            x ^= 0x0020;
                if ((i & 0x011800u) != 0x010000u)                            x ^= 0x0040;
                if ((i & 0x000820u) == 0x000820u)                            x ^= 0x0080;
                x ^= static_cast<uint16_t>(KOVSH_TAB[i & 0xff]) << 8;
            }
            break;
        case GAME_PHOTOY2K:
            if (word_addr < 0x280000u)
            {
                if ((i & 0x040080u) != 0x000080u) x ^= 0x0001;
                if ((i & 0x084008u) == 0x084008u) x ^= 0x0002;
                if ((i & 0x000030u) == 0x000010u) x ^= 0x0004;
                if ((i & 0x000242u) != 0x000042u) x ^= 0x0008;
                if ((i & 0x048100u) == 0x048000u) x ^= 0x0010;
                if ((i & 0x002004u) != 0x000004u) x ^= 0x0020;
                if ((i & 0x001800u) != 0)         x ^= 0x0040;
                if ((i & 0x004820u) == 0x004820u) x ^= 0x0080;
                x ^= static_cast<uint16_t>(PHOTOY2K_TAB[i & 0xff]) << 8;
            }
            break;
        case GAME_PUZZLI2:
            if (word_addr < 0x100000u)
            {
                if ((i & 0x040080u) != 0x000080u) x ^= 0x0001; // CRYPT1
                if ((i & 0x004008u) == 0x004008u) x ^= 0x0002; // CRYPT2_ALT
                if ((i & 0x000030u) == 0x000010u) x ^= 0x0004; // CRYPT3_ALT2
                if ((i & 0x000242u) != 0x000042u) x ^= 0x0008; // CRYPT4
                if ((i & 0x008100u) == 0x008000u) x ^= 0x0010; // CRYPT5
                if ((i & 0x022004u) != 0x000004u) x ^= 0x0020; // CRYPT6_ALT
                if ((i & 0x011800u) != 0x010000u) x ^= 0x0040; // CRYPT7
                if ((i & 0x004820u) == 0x004820u) x ^= 0x0080; // CRYPT8
                x ^= static_cast<uint16_t>(PUZZLI2_TAB[i & 0xff]) << 8;
            }
            break;
        case GAME_KET: // CAVE type1; whole prog encrypted (region word index from 0)
            if (word_addr < 0x180000u)
            {
                if ((i & 0x040480u) != 0x000080u) x ^= 0x0001; // CRYPT1
                if ((i & 0x004008u) == 0x004008u) x ^= 0x0002; // CRYPT2_ALT
                if ((i & 0x080030u) == 0x000010u) x ^= 0x0004; // CRYPT3_ALT3
                if ((i & 0x000042u) != 0x000042u) x ^= 0x0008; // CRYPT4_ALT
                if ((i & 0x008100u) == 0x008000u) x ^= 0x0010; // CRYPT5
                if ((i & 0x002004u) != 0x000004u) x ^= 0x0020; // CRYPT6
                if ((i & 0x011800u) != 0x010000u) x ^= 0x0040; // CRYPT7
                if ((i & 0x000820u) == 0x000820u) x ^= 0x0080; // CRYPT8_ALT
                x ^= static_cast<uint16_t>(KET_TAB[i & 0xff]) << 8;
            }
            break;
        case GAME_ESPGAL: // CAVE type1; whole prog encrypted
            if (word_addr < 0x180000u)
            {
                if ((i & 0x040480u) != 0x000080u) x ^= 0x0001; // CRYPT1
                if ((i & 0x084008u) == 0x084008u) x ^= 0x0002; // CRYPT2_ALT3
                if ((i & 0x000030u) == 0x000010u) x ^= 0x0004; // CRYPT3_ALT2
                if ((i & 0x000042u) != 0x000042u) x ^= 0x0008; // CRYPT4_ALT
                if ((i & 0x048100u) == 0x048000u) x ^= 0x0010; // CRYPT5_ALT
                if ((i & 0x022004u) != 0x000004u) x ^= 0x0020; // CRYPT6_ALT
                if ((i & 0x011800u) != 0x010000u) x ^= 0x0040; // CRYPT7
                if ((i & 0x000820u) == 0x000820u) x ^= 0x0080; // CRYPT8_ALT
                x ^= static_cast<uint16_t>(ESPGAL_TAB[i & 0xff]) << 8;
            }
            break;
        case GAME_DDP3: // CAVE type1; cart half only (=py2k2), region word index from 0
            if (word_addr < 0x180000u)
            {
                if ((i & 0x040480u) != 0x000080u) x ^= 0x0001; // CRYPT1
                if ((i & 0x084008u) == 0x084008u) x ^= 0x0002; // CRYPT2_ALT3
                if (((i & 0x000030u) == 0x000010u) && ((i & 0x180000u) != 0x080000u)) x ^= 0x0004; // CRYPT3_ALT
                if ((i & 0x000042u) != 0x000042u) x ^= 0x0008; // CRYPT4_ALT
                if ((i & 0x008100u) == 0x008000u) x ^= 0x0010; // CRYPT5
                if ((i & 0x022004u) != 0x000004u) x ^= 0x0020; // CRYPT6_ALT
                if ((i & 0x011800u) != 0x010000u) x ^= 0x0040; // CRYPT7
                if ((i & 0x004820u) == 0x004820u) x ^= 0x0080; // CRYPT8
                x ^= static_cast<uint16_t>(PY2K2_TAB[i & 0xff]) << 8;
            }
            break;
        default:
            break;
        }
        if (x)
        {
            uint16_t v = static_cast<uint16_t>(buf[2 * k]) | (static_cast<uint16_t>(buf[2 * k + 1]) << 8);
            v ^= x;
            buf[2 * k]     = static_cast<uint8_t>(v & 0xff);
            buf[2 * k + 1] = static_cast<uint8_t>(v >> 8);
        }
    }
}

// type3 external-ARM-ROM high-byte tables (MAME pgmcrypt.cpp), indexed by
// (word_index >> 1) & 0xff.  Must match the DFRONT_TAB/THEGLAD_TAB in
// rtl/exrom_decrypt.sv.
const uint8_t DFRONT_TAB[256] = {
    0x51, 0xc4, 0xe3, 0x10, 0x1c, 0xad, 0x8a, 0x39, 0x8c, 0xe0, 0xa5, 0x04, 0x0f, 0xe4, 0x35, 0xc3,
    0x2d, 0x6b, 0x32, 0xe2, 0x60, 0x54, 0x63, 0x06, 0xa3, 0xf1, 0x0b, 0x5f, 0x6c, 0x5c, 0xb3, 0xec,
    0x77, 0x61, 0x69, 0xe7, 0x3c, 0xb7, 0x42, 0x72, 0x1a, 0x70, 0xb0, 0x96, 0xa4, 0x28, 0xc0, 0xfb,
    0x0a, 0x00, 0xcb, 0x15, 0x49, 0x48, 0xd3, 0x94, 0x58, 0xcf, 0x41, 0x86, 0x17, 0x71, 0xb1, 0xbd,
    0x21, 0x01, 0x37, 0x1e, 0xba, 0xeb, 0xf3, 0x59, 0xf6, 0xa7, 0x29, 0x4f, 0xb5, 0xca, 0x4c, 0x34,
    0x20, 0xa2, 0x62, 0x4b, 0x93, 0x9e, 0x47, 0x9f, 0x8d, 0x0e, 0x1b, 0xb6, 0x4d, 0x82, 0xd5, 0xf4,
    0x85, 0x79, 0x53, 0x92, 0x9b, 0xf7, 0xea, 0x44, 0x76, 0x1f, 0x22, 0x45, 0xed, 0xbe, 0x11, 0x55,
    0xaf, 0xf5, 0xf8, 0x50, 0x07, 0xe6, 0xc7, 0x5e, 0xd7, 0xde, 0xe5, 0x26, 0x2b, 0xf2, 0x6a, 0x8b,
    0xb8, 0x98, 0x89, 0xdb, 0x14, 0x5b, 0xc5, 0x78, 0xdc, 0xd0, 0x87, 0x5d, 0xc1, 0x0d, 0x95, 0x97,
    0x7e, 0xa8, 0x24, 0x3d, 0xe1, 0xd1, 0x19, 0xa6, 0x99, 0xd8, 0x83, 0x1d, 0xff, 0x30, 0x9d, 0x05,
    0xd4, 0x02, 0x27, 0x7b, 0x13, 0xb2, 0x7f, 0x40, 0x12, 0xa0, 0x68, 0x67, 0x4e, 0x3a, 0x46, 0xb9,
    0xee, 0xdf, 0x66, 0xd6, 0x8f, 0xa9, 0x0c, 0x91, 0x65, 0x18, 0x52, 0x56, 0xd9, 0x74, 0x09, 0x6e,
    0xc6, 0x73, 0xc9, 0xfc, 0x03, 0x43, 0xef, 0xaa, 0x7c, 0xbb, 0x2c, 0x90, 0xcc, 0xce, 0xe8, 0xae,
    0x2a, 0xf9, 0x57, 0x88, 0xc8, 0xe9, 0x5a, 0xdd, 0x2e, 0x7d, 0x64, 0xc2, 0x6d, 0x3e, 0xfa, 0x80,
    0x16, 0xcd, 0x6f, 0x84, 0x8e, 0x9c, 0xf0, 0xac, 0xb4, 0x9a, 0x2f, 0xbc, 0x31, 0x23, 0xfe, 0x38,
    0x08, 0x75, 0xa1, 0x33, 0xab, 0xd2, 0xda, 0x81, 0xbf, 0x7a, 0x3b, 0x3f, 0x4a, 0xfd, 0x25, 0x36,
};

const uint8_t THEGLAD_TAB[256] = {
    0x49, 0x47, 0x53, 0x30, 0x30, 0x30, 0x35, 0x52, 0x44, 0x31, 0x30, 0x32, 0x31, 0x32, 0x30, 0x33,
    0xc4, 0xa3, 0x46, 0x78, 0x30, 0xb3, 0x8b, 0xd5, 0x2f, 0xc4, 0x44, 0xbf, 0xdb, 0x76, 0xdb, 0xea,
    0xb4, 0xeb, 0x95, 0x4d, 0x15, 0x21, 0x99, 0xa1, 0xd7, 0x8c, 0x40, 0x1d, 0x43, 0xf3, 0x9f, 0x71,
    0x3d, 0x8c, 0x52, 0x01, 0xaf, 0x5b, 0x8b, 0x63, 0x34, 0xc8, 0x5c, 0x1b, 0x06, 0x7f, 0x41, 0x96,
    0x2a, 0x8d, 0xf1, 0x64, 0xda, 0xb8, 0x67, 0xba, 0x33, 0x1f, 0x2b, 0x28, 0x20, 0x13, 0xe6, 0x96,
    0x86, 0x34, 0x25, 0x85, 0xb0, 0xd0, 0x6d, 0x85, 0xfe, 0x78, 0x81, 0xf1, 0xca, 0xe4, 0xef, 0xf2,
    0x9b, 0x09, 0xe1, 0xb4, 0x8d, 0x79, 0x22, 0xe2, 0x00, 0xfb, 0x6f, 0x68, 0x80, 0x6a, 0x00, 0x69,
    0xf5, 0xd3, 0x57, 0x7e, 0x0c, 0xca, 0x48, 0x31, 0xe5, 0x0d, 0x4a, 0xb9, 0xfd, 0x5c, 0xfd, 0xf8,
    0x5f, 0x98, 0xfb, 0xb3, 0x07, 0x1a, 0xe3, 0x10, 0x96, 0x56, 0xa3, 0x56, 0x3d, 0xb1, 0x07, 0xe0,
    0xe3, 0x9f, 0x7f, 0x62, 0x99, 0x01, 0x35, 0x60, 0x40, 0xbe, 0x4f, 0xeb, 0x79, 0xa0, 0x82, 0x9f,
    0xcd, 0x71, 0xd8, 0xda, 0x1e, 0x56, 0xc2, 0x3e, 0x4e, 0x6b, 0x60, 0x69, 0x2d, 0x9f, 0x10, 0xf4,
    0xa9, 0xd3, 0x36, 0xaa, 0x31, 0x2e, 0x4c, 0x0a, 0x69, 0xc3, 0x2a, 0xff, 0x15, 0x67, 0x96, 0xde,
    0x3f, 0xcc, 0x0f, 0xa1, 0xac, 0xe2, 0xd6, 0x62, 0x7e, 0x6f, 0x3e, 0x1b, 0x2a, 0xed, 0x36, 0x9c,
    0x9d, 0xa4, 0x14, 0xcd, 0xaa, 0x08, 0xa4, 0x26, 0xb7, 0x55, 0x70, 0x6c, 0xa9, 0x69, 0x52, 0xae,
    0x0c, 0xe1, 0x38, 0x7f, 0x87, 0x78, 0x38, 0x75, 0x80, 0x9c, 0xd4, 0xe2, 0x0b, 0x52, 0x8f, 0xd2,
    0x19, 0x4c, 0xb0, 0x45, 0xde, 0x48, 0x55, 0xae, 0x82, 0xab, 0xbc, 0xab, 0x0c, 0x5e, 0xce, 0x07,
};

const uint8_t KILLBLDP_TAB[256] = {
    0x49, 0x47, 0x53, 0x30, 0x30, 0x32, 0x34, 0x52, 0x44, 0x31, 0x30, 0x35, 0x30, 0x39, 0x30, 0x38,
    0x12, 0xa0, 0xd1, 0x9e, 0xb1, 0x8a, 0xfb, 0x1f, 0x50, 0x51, 0x4b, 0x81, 0x28, 0xda, 0x5f, 0x41,
    0x78, 0x6c, 0x7a, 0xf0, 0xcd, 0x6b, 0x69, 0x14, 0x94, 0x55, 0xb6, 0x42, 0xdf, 0xfe, 0x10, 0x79,
    0x74, 0x08, 0xfa, 0xc0, 0x1c, 0xa5, 0xb4, 0x03, 0x2a, 0x91, 0x67, 0x2b, 0x49, 0x4a, 0x94, 0x7d,
    0x8b, 0x92, 0xbe, 0x35, 0xaf, 0x28, 0x56, 0x63, 0xb3, 0xc2, 0xe8, 0x06, 0x9b, 0x4e, 0x85, 0x66,
    0x7f, 0x6b, 0x70, 0xb7, 0xdb, 0x22, 0x0c, 0xeb, 0x13, 0xe9, 0x06, 0xd7, 0x45, 0xda, 0xbe, 0x8b,
    0x54, 0x30, 0xfc, 0xeb, 0x32, 0x02, 0xd0, 0x92, 0x6d, 0x44, 0xca, 0xe8, 0xfd, 0xfb, 0x5b, 0x81,
    0x4c, 0xc0, 0x8b, 0xb9, 0x87, 0x78, 0xdd, 0x8e, 0x24, 0x52, 0x80, 0xbe, 0xb4, 0x01, 0xb7, 0x21,
    0xeb, 0x3c, 0x8a, 0x49, 0xed, 0x73, 0xae, 0x58, 0xdb, 0xd2, 0xb2, 0x21, 0x9e, 0x7c, 0x6c, 0x82,
    0xf3, 0x01, 0xa3, 0x00, 0xb7, 0x21, 0xfe, 0xa5, 0x75, 0xc4, 0x2d, 0x17, 0x2d, 0x39, 0x56, 0xf9,
    0x67, 0xae, 0xc2, 0x87, 0x79, 0xf1, 0xc8, 0x6d, 0x15, 0x66, 0xfa, 0xe8, 0x16, 0x48, 0x8f, 0x1f,
    0x8b, 0x24, 0x10, 0xc4, 0x04, 0x93, 0x47, 0xe6, 0x1d, 0x37, 0x65, 0x1a, 0x49, 0xf8, 0x72, 0xcb,
    0xe1, 0x80, 0xfa, 0xdd, 0x6d, 0xf5, 0xf6, 0x89, 0x32, 0xf6, 0xf8, 0x75, 0xfc, 0xd8, 0x9b, 0x12,
    0x2d, 0x22, 0x2a, 0x3b, 0x06, 0x46, 0x90, 0x0c, 0x35, 0xa2, 0x80, 0xff, 0xa0, 0xb7, 0xe5, 0x4d,
    0x71, 0xa9, 0x8c, 0x84, 0x62, 0xf7, 0x10, 0x65, 0x4a, 0x7b, 0x06, 0x00, 0xe8, 0xa4, 0x6a, 0x13,
    0xf0, 0xf3, 0x4a, 0x9f, 0x54, 0xb4, 0xb1, 0xcc, 0xd4, 0xff, 0xd6, 0xff, 0xc9, 0xee, 0x86, 0x39,
};

const uint8_t HAPPY6_TAB[256] = { // IGS0008RD1031215
    0x49, 0x47, 0x53, 0x30, 0x30, 0x30, 0x38, 0x52, 0x44, 0x31, 0x30, 0x33, 0x31, 0x32, 0x31, 0x35,
    0x14, 0xd6, 0x37, 0x5c, 0x5e, 0xc3, 0xd3, 0x62, 0x96, 0x3d, 0xfb, 0x47, 0xf0, 0xcb, 0xbf, 0xb0,
    0x60, 0xa1, 0xc2, 0x3d, 0x90, 0xd0, 0x58, 0x56, 0x22, 0xac, 0xdd, 0x39, 0x27, 0x7e, 0x58, 0x44,
    0xe0, 0x6b, 0x51, 0x80, 0xb4, 0xa4, 0xf0, 0x6f, 0x71, 0xd0, 0x57, 0x18, 0xc7, 0xb6, 0x41, 0x50,
    0x02, 0x2f, 0xdb, 0x4a, 0x08, 0x4b, 0xe3, 0x62, 0x92, 0xc3, 0xff, 0x26, 0xaf, 0x9f, 0x60, 0xa5,
    0x76, 0x28, 0x97, 0xfd, 0x0b, 0x10, 0xb7, 0x1f, 0xd5, 0xe0, 0xac, 0xe6, 0xfd, 0xa3, 0xdb, 0x58,
    0x2a, 0xd1, 0xfc, 0x3b, 0x7c, 0x7e, 0x34, 0xdc, 0xc7, 0xc4, 0x76, 0x1b, 0x11, 0x6d, 0x1b, 0xbb,
    0x4e, 0xe5, 0xc0, 0xe8, 0x5a, 0x60, 0x60, 0x0a, 0x38, 0x47, 0xb3, 0xc9, 0x89, 0xe9, 0xc6, 0x61,
    0x50, 0x5f, 0xdb, 0x28, 0xe5, 0xc0, 0x83, 0x5c, 0x37, 0x86, 0xfa, 0x32, 0x46, 0x40, 0xc3, 0x1d,
    0xdf, 0x7a, 0x85, 0x5c, 0x9a, 0xea, 0x24, 0xc7, 0x12, 0xdc, 0x23, 0xda, 0x65, 0xdf, 0x39, 0x02,
    0xeb, 0xb1, 0x32, 0x28, 0x3a, 0x69, 0x09, 0x7c, 0x5a, 0xe3, 0x44, 0x83, 0x45, 0x71, 0x8f, 0x64,
    0xa3, 0xbf, 0x9c, 0x6f, 0xc4, 0x07, 0x3a, 0xee, 0xdd, 0x77, 0xb4, 0x31, 0x87, 0xdf, 0x6d, 0xd4,
    0x75, 0x9f, 0xb9, 0x53, 0x75, 0xd0, 0xfe, 0xd1, 0xaa, 0xb2, 0x0b, 0x25, 0x08, 0x56, 0xb8, 0x27,
    0x10, 0x8c, 0xbf, 0x39, 0xce, 0x0f, 0xdb, 0x18, 0x10, 0xf0, 0x1f, 0xe5, 0xe8, 0x40, 0x98, 0x6f,
    0x64, 0x02, 0x27, 0xc3, 0x8c, 0x4f, 0x98, 0xf6, 0x9d, 0xcb, 0x07, 0x31, 0x85, 0x48, 0x75, 0xff,
    0x9f, 0xba, 0xa6, 0xd3, 0xb0, 0x5b, 0x3d, 0xdd, 0x22, 0x1f, 0x1b, 0x0e, 0x7f, 0x5a, 0xf4, 0x6a,
};

// ARM external ROM address-bit XOR (must match rtl/exrom_decrypt.sv).
void DecryptArmExrom(Game game, std::vector<uint8_t> &buf)
{
    const size_t n = buf.size() / 2;
    for (size_t k = 0; k < n; k++)
    {
        const uint32_t i = static_cast<uint32_t>(k);
        // IGS27_CRYPT* primitives (MAME pgmcrypt.cpp).
        const bool c1   = ((i & 0x040480u) != 0x000080u);
        const bool c1a  = ((i & 0x040080u) != 0x000080u);
        const bool c1a2 = ((i & 0x000480u) != 0x000080u);
        const bool c2   = ((i & 0x104008u) == 0x104008u);
        const bool c2a  = ((i & 0x004008u) == 0x004008u);
        const bool c3   = ((i & 0x080030u) == 0x080010u);
        const bool c3a2 = ((i & 0x000030u) == 0x000010u);
        const bool c4   = ((i & 0x000242u) != 0x000042u);
        const bool c4a  = ((i & 0x000042u) != 0x000042u);
        const bool c5   = ((i & 0x008100u) == 0x008000u);
        const bool c5a  = ((i & 0x048100u) == 0x048000u);
        const bool c6   = ((i & 0x002004u) != 0x000004u);
        const bool c6a  = ((i & 0x022004u) != 0x000004u);
        const bool c7   = ((i & 0x011800u) != 0x010000u);
        const bool c7a  = ((i & 0x001800u) != 0x000000u);
        const bool c8   = ((i & 0x004820u) == 0x004820u);
        const bool c8a  = ((i & 0x000820u) == 0x000820u);

        auto B = [](bool b, int s) -> uint16_t { return b ? static_cast<uint16_t>(1u << s) : 0; };
        uint16_t m = 0;
        switch (game)
        {
        case GAME_KOV2:
            m = B(c1a,0) |            B(c3,2)   | B(c4a,3) | B(c5a,4) | B(c6a,5) | B(c7a,6) | B(c8a,7);
            break;
        case GAME_KOV2P:
            m = B(c1a,0) | B(c2a,1) | B(c3,2)  | B(c4,3)  | B(c5,4)  | B(c6,5)  | B(c7,6)  | B(c8a,7);
            break;
        case GAME_DDP2:
            m = B(c1a2,0) |                       B(c4a,3) | B(c5,4)  | B(c6,5)  | B(c7a,6) | B(c8a,7);
            break;
        case GAME_MARTMAST:
        case GAME_DW2001:
            m = B(c1,0)  | B(c2a,1) | B(c3a2,2)| B(c4,3)  | B(c5,4)  | B(c6a,5) | B(c7,6)  | B(c8a,7);
            break;
        case GAME_DWPC:
            m = B(c1a,0) | B(c2,1)  | B(c3,2)  | B(c4a,3) | B(c5a,4) | B(c6,5)  | B(c7a,6) | B(c8,7);
            break;
        // type3 (55857G): low byte = address-bit XOR, high byte = per-game table
        // indexed by (word_index >> 1) & 0xff.
        case GAME_DMNFRNT:
            m = B(c1a,0) | B(c2,1)  | B(c3,2)  | B(c4a,3) | B(c5,4)  | B(c6,5)  | B(c7,6)  | B(c8,7)
                | static_cast<uint16_t>(DFRONT_TAB[(i >> 1) & 0xff] << 8);
            break;
        case GAME_THEGLAD:
            m = B(c1a,0) | B(c2,1)  | B(c3,2)  | B(c4a,3) | B(c5,4)  | B(c6a,5) | B(c7,6)  | B(c8a,7)
                | static_cast<uint16_t>(THEGLAD_TAB[(i >> 1) & 0xff] << 8);
            break;
        case GAME_KILLBLDP:
            m = B(c1,0)  | B(c2,1)  | B(c3,2)  | B(c4,3)  | B(c5,4)  | B(c6,5)  | B(c7,6)  | B(c8a,7)
                | static_cast<uint16_t>(KILLBLDP_TAB[(i >> 1) & 0xff] << 8);
            break;
        case GAME_HAPPY6:
            m = B(c1,0)  | B(c2,1)  | B(c3,2)  | B(c4,3)  | B(c5a,4) | B(c6,5)  | B(c7,6)  | B(c8a,7)
                | static_cast<uint16_t>(HAPPY6_TAB[(i >> 1) & 0xff] << 8);
            break;
        // svg: pgm_svg_decrypt applies only the IGS27 bit permutations; NO
        // high-byte table XOR (high byte unchanged).
        case GAME_SVG:
            m = B(c1a,0) | B(c2a,1) | B(c3,2)  | B(c4a,3) | B(c5a,4) | B(c6,5)  | B(c7,6)  | B(c8a,7);
            break;
        default:
            m = 0;
            break;
        }
        if (m)
        {
            uint16_t v = static_cast<uint16_t>(buf[2 * k]) | (static_cast<uint16_t>(buf[2 * k + 1]) << 8);
            v ^= m;
            buf[2 * k]     = static_cast<uint8_t>(v & 0xff);
            buf[2 * k + 1] = static_cast<uint8_t>(v >> 8);
        }
    }
}

// Load a 68k cart program region in NORMAL byte order (raw file bytes; PGM
// program ROMs are WORD_SWAP so a little-endian read of the raw file yields the
// 68k word).  Decryption (if any) is applied here to match the RTL rom_loader.
bool LoadProgRom(Game game, const char *name, uint32_t crc, uint32_t destBase,
                 size_t fileOffset = 0, size_t length = 0)
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

    std::vector<uint8_t> prog(buffer.begin() + fileOffset, buffer.begin() + fileOffset + length);
    const uint32_t wordBase = (destBase - CART_PROG_ROM_SDR_BASE) / 2; // region word offset
    Decrypt68kProg(game, prog, wordBase);

    gSimCore.mSDRAM->Write(destBase, static_cast<uint32_t>(prog.size()), prog.data());
    printf("Loaded %zu bytes (NORMAL) from %s offset 0x%zx to SDRAM 0x%08X\n", prog.size(), name, fileOffset, destBase);
    return true;
}

// Load the external ARM ROM into DDR, decrypted (address-bit XOR) at load.
bool LoadArmExrom(Game game, const char *name, uint32_t crc, uint32_t destBase)
{
    std::vector<uint8_t> buffer;
    if (!LoadFileByNameOrCrc(name, crc, buffer))
        return false;

    DecryptArmExrom(game, buffer);

    if (!gSimCore.mDDRMemory->LoadData(buffer, destBase, 1))
        return false;

    printf("Loaded %zu bytes (decrypted) from %s to DDR 0x%08X\n", buffer.size(), name, destBase);
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
    "kov2p",
    "ddp2",
    "martmast",
    "dw2001",
    "dwpc",
    "dmnfrnt",
    "theglad",
    "svg",
    "ket",
    "espgal",
    "ddp3",
    "killbldp",
    "happy6",
    "dwex",
    "puzzli2",
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
    gSimCore.mSDRAM->LoadData("pgm_a0600.u1", CART_A_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("pgm_a0601.u3", CART_A_ROM_SDR_BASE + 0x0800000, 1);
    gSimCore.mSDRAM->LoadData("pgm_a0602.u5", CART_A_ROM_SDR_BASE + 0x1000000, 1);
    gLoadedGameShortName = "pgm_test";
    gSimCore.SetGame(GAME_PGM_TEST);
}


static void LoadTestbios()
{
    AddRomZip("pgm");

    gSimCore.mSDRAM->LoadData("testbios.bin", BIOS_PROG_ROM_SDR_BASE, 1);
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

    gSimCore.mSDRAM->LoadData("espgaluda_u8.bin", CART_PROG_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_t04801w064.u19", CART_TILE_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_b04801w064.u1", CART_B_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_w04801b032.u17", CART_MUSIC_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_a04801w064.u7", CART_A_ROM_SDR_BASE, 1);
    gSimCore.mSDRAM->LoadData("cave_a04802w064.u8", CART_A_ROM_SDR_BASE + 0x0800000, 1);

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

    LoadProgRom(GAME_PGM, "p0103.rom", 0xd5e93543, CART_PROG_ROM_SDR_BASE);
    LoadSdramData("pgm_t0100.u8", 0x61425e1e, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0100.u5", 0x8b3bd88a, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0101.u6", 0x3b9e9644, CART_A_ROM_SDR_BASE + 0x0400000);
    LoadSdramData("pgm_a0102.u7", 0x069e2c38, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a0103.u8", 0x4460a3fd, CART_A_ROM_SDR_BASE + 0x0c00000);
    LoadSdramData("pgm_a0104.u11", 0x5f8abb56, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a0105.u12", 0xa17a7147, CART_A_ROM_SDR_BASE + 0x1400000);
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

    LoadProgRom(GAME_PGM, "ketsui_u1.bin", 0x391767b4, CART_PROG_ROM_SDR_BASE, 0x200000, 0x200000);
    LoadSdramData("t04701w064.u19", 0x2665b041, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("b04701w064.u1", 0x1bec008d, CART_B_ROM_SDR_BASE);
    LoadSdramData("a04701w064.u7", 0x5ef1b94b, CART_A_ROM_SDR_BASE);
    LoadSdramData("a04702w064.u8", 0x26d6da7f, CART_A_ROM_SDR_BASE + 0x0800000);
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

    LoadProgRom(GAME_PGM, "ddp_doj_u1.bin", 0xeb4ab06a, CART_PROG_ROM_SDR_BASE);
    LoadSdramData("t04401w064.u19", 0x3a95f19c, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("b04401w064_corrupt.u1", 0x8cbff066, CART_B_ROM_SDR_BASE);
    LoadSdramData("a04401w064.u7", 0xed229794, CART_A_ROM_SDR_BASE);
    LoadSdramData("a04402w064.u8", 0x752167b0, CART_A_ROM_SDR_BASE + 0x0800000);
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

    LoadProgRom(GAME_PGM, "prg1.29f1610ml", prg1Crc, CART_PROG_ROM_SDR_BASE);
    LoadProgRom(GAME_PGM, "prg2.am27c4096", 0x7b3577dc, CART_PROG_ROM_SDR_BASE + 0x200000);
    LoadSdramData("t0600a 1610", 0x64e406a1, CART_TILE_ROM_SDR_BASE + 0x000000);
    LoadSdramData("t0600b 1610", 0x26591209, CART_TILE_ROM_SDR_BASE + 0x200000);
    LoadSdramData("t0600c 1610", 0x461dc80c, CART_TILE_ROM_SDR_BASE + 0x400000);
    LoadSdramData("t0600d 1610", 0xf7e6b529, CART_TILE_ROM_SDR_BASE + 0x600000);
    LoadSdramData("pgm_b0600.u5", 0x7d3cd059, CART_B_ROM_SDR_BASE + 0x000000);
    LoadSdramData("pgm_b0601.u7", 0xa0bb1c2f, CART_B_ROM_SDR_BASE + 0x800000);
    LoadSdramData("pgm_a0600.u2", 0xd8167834, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0601.u4", 0xff7a4373, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a0602.u6", 0xe7a32959, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a0603.u9", 0xec31abda, CART_A_ROM_SDR_BASE + 0x1800000);
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

    // Encrypted 68000 program (decrypted at load).  Single WORD_SWAP ROM.
    LoadProgRom(GAME_KILLBLD, "p0300_v109.u9", 0x2fcee215, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t0300.u14", 0x0922f7d9, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0300.u9", 0x3f9455d3, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0301.u10", 0x92776889, CART_A_ROM_SDR_BASE + 0x0400000);
    LoadSdramData("pgm_a0303.u11", 0x33f5cc69, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a0306.u12", 0xcc018a8e, CART_A_ROM_SDR_BASE + 0x0c00000);
    LoadSdramData("pgm_a0307.u2", 0xbc772e39, CART_A_ROM_SDR_BASE + 0x1000000);
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

    // Encrypted 68000 program (decrypted at load).  Two LOAD16_BYTE ROMs:
    //   dw3_v106_u13.u13 -> even byte addresses (high byte of each 68k word)
    //   dw3_v106_u12.u12 -> odd  byte addresses (low  byte of each 68k word)
    // SDRAM stores the 68k word little-endian (read = SDRAM[2k+1]<<8|SDRAM[2k]),
    // so the cleartext word = uEven<<8|uOdd is stored {lo=uOdd, hi=uEven}; then
    // Decrypt68kProg applies the per-game XOR in place.
    {
        std::vector<uint8_t> uEven, uOdd;
        if (LoadFileByNameOrCrc("dw3_v106_u13.u13", 0x28284e22, uEven) &&
            LoadFileByNameOrCrc("dw3_v106_u12.u12", 0xc3f6838b, uOdd))
        {
            const size_t half = std::min(uEven.size(), uOdd.size());
            std::vector<uint8_t> prog(half * 2);
            for (size_t k = 0; k < half; k++)
            {
                prog[2 * k + 0] = uOdd[k];  // low byte
                prog[2 * k + 1] = uEven[k]; // high byte
            }
            Decrypt68kProg(GAME_DRGW3, prog);
            gSimCore.mSDRAM->Write(CART_PROG_ROM_SDR_BASE,
                                   static_cast<uint32_t>(prog.size()), prog.data());
            printf("Loaded %zu bytes interleaved+decrypted drgw3 program to SDRAM 0x%08X\n",
                   prog.size(), CART_PROG_ROM_SDR_BASE);
        }
    }

    LoadSdramData("pgm_t0400.u18", 0xb70f3357, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0400.u9", 0xdd7bfd40, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0401.u10", 0xcab6557f, CART_A_ROM_SDR_BASE + 0x0400000);
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

// Dragon World 3 EX (V100).  Same board behavior as drgw3 (MAME uses the same
// pgm_022_025_dw3 machine and init_drgw3, and the IGS022 data ROM content is
// identical), so it runs with the GAME_DRGW3 board id.
static void LoadDwex()
{
    LoadPgm();

    AddRomZip("dwex");

    {
        std::vector<uint8_t> uEven, uOdd;
        if (LoadFileByNameOrCrc("dwex_v100.u13", 0x7afe6322, uEven) &&
            LoadFileByNameOrCrc("dwex_v100.u12", 0xbc171799, uOdd))
        {
            const size_t half = std::min(uEven.size(), uOdd.size());
            std::vector<uint8_t> prog(half * 2);
            for (size_t k = 0; k < half; k++)
            {
                prog[2 * k + 0] = uOdd[k];  // low byte
                prog[2 * k + 1] = uEven[k]; // high byte
            }
            Decrypt68kProg(GAME_DRGW3, prog);
            gSimCore.mSDRAM->Write(CART_PROG_ROM_SDR_BASE,
                                   static_cast<uint32_t>(prog.size()), prog.data());
            printf("Loaded %zu bytes interleaved+decrypted dwex program to SDRAM 0x%08X\n",
                   prog.size(), CART_PROG_ROM_SDR_BASE);
        }
    }

    LoadSdramData("pgm_t0400.u18", 0x9ecc950d, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0400.u9", 0xdd7bfd40, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0401.u10", 0xd36c06a4, CART_A_ROM_SDR_BASE + 0x0400000);
    LoadSdramData("pgm_b0400.u13", 0x4bb87cc0, CART_B_ROM_SDR_BASE);
    LoadSdramData("pgm_m0400.u1", 0x42d54fd5, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs022ProtRom("dwiii_data_u15.u15", 0x03dc4fdf);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "dwex";
    gSimCore.SetGame(GAME_DRGW3);
}


// Load the 16KB IGS027A internal ARM ROM into DDR (shared prot_cache).
// On real hardware this arrives via the rom_loader DDR path (LOAD_REGIONS
// index 9 -> PROT_INT_ROM_DDR_BASE); raw bytes, little-endian as the ARM reads.
static bool LoadIgs027aIntRom(const char *name, uint32_t crc)
{
    // Dumped internal ROMs (kovsh/photoy2k) live inside the game zip; the CAVE
    // recreation (type1_cave.bin) is a loose file in the ROM dir, so make sure the
    // ROM dir itself is on the search path for loose-file lookups.
    gFileSearch.AddSearchPath(RomDir());
    return LoadDdrData(name, crc, PROT_INT_ROM_DDR_BASE);
}

static void LoadKovsh()
{
    LoadPgm();
    AddRomZip("kovsh");
    AddRomZip("kov");

    // 68000 program (encrypted; decrypted at load), WORD_SWAP, 4MB.
    LoadProgRom(GAME_KOVSH, "pgm_p0605_v104.u1", 0x7c78e5f3, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t0600.u11", 0x4acc1ad6, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0600.u1", 0xd8167834, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0601.u3", 0xff7a4373, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a0602.u5", 0xe7a32959, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a0613.u7", 0xec31abda, CART_A_ROM_SDR_BASE + 0x1800000);
    LoadSdramData("pgm_a0604_v200.u9", 0x26b59fd3, CART_A_ROM_SDR_BASE + 0x1a00000);
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

    // 68000 program (encrypted; decrypted at load), WORD_SWAP, 2MB.
    LoadProgRom(GAME_PHOTOY2K, "pgm_p0701_v105.u2", 0xfab142e0, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t0700.u11", 0x93943b4d, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0700.u2", 0x503c855b, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a0701.u4", 0x845e11a8, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a0702.u3", 0x42239e1b, CART_A_ROM_SDR_BASE + 0x1000000);
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

static void LoadPuzzli2()
{
    LoadPgm();
    AddRomZip("puzzli2");

    // 68000 program (encrypted; decrypted at load), WORD_SWAP, 2MB; decrypt covers first 1MB.
    LoadProgRom(GAME_PUZZLI2, "v100_u5.u5", 0x1abb4595, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t0900.u9", 0x70615611, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a0900.u3", 0x14911251, CART_A_ROM_SDR_BASE);
    LoadSdramData("pgm_b0900.u4", 0x6f0638b6, CART_B_ROM_SDR_BASE);
    LoadSdramData("pgm_m0900.u2", 0x9ea7af2e, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("type1_puzzli2.bin", 0);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "puzzli2";
    gSimCore.SetGame(GAME_PUZZLI2);
}

// CAVE IGS027A type1 games.  Internal ROM was never dumped; we run the real ARM7
// against the RetroHQ recreation (type1_cave.bin, 16KB) which implements MAME's
// command_handler_ddp3 over the real latch.  One binary serves all three.  68k
// program is encrypted (pgm_{ket,espgal,py2k2}_decrypt).  Latch-only protocol.

// Ketsui (BIOS-less: game program at 68k 0x000000, cart_prog_base=0).
static void LoadKet()
{
    LoadPgm();
    AddRomZip("ket");

    LoadProgRom(GAME_KET, "ketsui_v100.u38", 0xdfe62f3b, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("cave_t04701w064.u19", 0x2665b041, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("cave_a04701w064.u7", 0x5ef1b94b, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("cave_a04702w064.u8", 0x26d6da7f, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("cave_b04701w064.u1", 0x1bec008d, CART_B_ROM_SDR_BASE);
    LoadSdramData("cave_m04701b032.u17", 0xb46e22d1, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("type1_cave_fixed.bin", 0xe2d930af);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "ket";
    gSimCore.SetGame(GAME_KET);
}

// Espgaluda (BIOS-less, mirrors ket).
static void LoadEspgal()
{
    LoadPgm();
    AddRomZip("espgal");

    LoadProgRom(GAME_ESPGAL, "espgaluda_v100.u38", 0x08ecec34, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("cave_t04801w064.u19", 0x6021c79e, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("cave_a04801w064.u7", 0x26dd4932, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("cave_a04802w064.u8", 0x0e6bf7a9, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("cave_b04801w064.u1", 0x98dce13a, CART_B_ROM_SDR_BASE);
    LoadSdramData("cave_w04801b032.u17", 0x60298536, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("type1_cave_fixed.bin", 0xe2d930af);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "espgal";
    gSimCore.SetGame(GAME_ESPGAL);
}

// DoDonPachi Dai-Ou-Jou (standard layout: hacked BIOS @0x0 + cart @0x100000).
// Only the cart half is encrypted (pgm_py2k2_decrypt); the BIOS is plaintext.
static void LoadDdp3()
{
    LoadPgm();
    AddRomZip("ddp3");

    LoadProgRom(GAME_PGM,  "ddp3_bios.u37",     0xb3cc5c8f, BIOS_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadProgRom(GAME_DDP3, "ddp3_v101_16m.u36", 0xfba2180e, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("cave_t04401w064.u19", 0x3a95f19c, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("cave_a04401w064.u7", 0xed229794, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("cave_a04402w064.u8", 0x752167b0, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("cave_b04401w064.u1", 0x17731c9d, CART_B_ROM_SDR_BASE);
    LoadSdramData("cave_m04401b032.u17", 0x5a0dbd76, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("type1_cave_fixed.bin", 0xe2d930af);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;

    gLoadedGameShortName = "ddp3";
    gSimCore.SetGame(GAME_DDP3);
}

static void LoadKov2()
{
    LoadPgm();
    AddRomZip("kov2");

    // 68000 program (plaintext, WORD_SWAP, 4MB).
    LoadProgRom(GAME_KOV2, "v107_u18.u18", 0x661a5b2c, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t1200.u27", 0xd7e26609, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a1200.u1", 0xceeb81d8, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a1201.u4", 0x21063ca7, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a1202.u6", 0x4bb92fae, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a1203.u8", 0xe73cb627, CART_A_ROM_SDR_BASE + 0x1800000);
    LoadSdramData("pgm_a1204.u10", 0x14b4b5bb, CART_A_ROM_SDR_BASE + 0x2000000);
    LoadSdramData("pgm_b1200.u5", 0xbed7d994, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b1201.u7", 0xf251eb57, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m1200.u3", 0xb0d88720, CART_MUSIC_ROM_SDR_BASE);

    LoadIgs027aIntRom("kov2_v100_hongkong.asic", 0xe0d7679f);

    // External ARM ROM (2MB, encrypted): decrypted at load (address-bit XOR).
    // The rom_loader/MRA DDR path applies the same exrom_decrypt, so both paths
    // place identical decrypted bytes at CART_ARM_ROM_DDR_BASE.
    LoadArmExrom(GAME_KOV2, "v102_u19.u19", 0x462e2980, CART_ARM_ROM_DDR_BASE);

    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x800000;

    gLoadedGameShortName = "kov2";
    gSimCore.SetGame(GAME_KOV2);
}

// Knights of Valour 2 Plus - Nine Dragons (v205).  Shares kov2 gfx/audio.
static void LoadKov2p()
{
    LoadPgm();
    AddRomZip("kov2p");
    LoadProgRom(GAME_KOV2P, "v205_32m.u8", 0x3a2cc0de, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t1200.u21", 0xd7e26609, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a1200.u1", 0xceeb81d8, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a1201.u4", 0x21063ca7, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a1202.u6", 0x4bb92fae, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a1203.u8", 0xe73cb627, CART_A_ROM_SDR_BASE + 0x1800000);
    LoadSdramData("pgm_a1204.u10", 0x14b4b5bb, CART_A_ROM_SDR_BASE + 0x2000000);
    LoadSdramData("pgm_b1200.u5", 0xbed7d994, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b1201.u7", 0xf251eb57, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m1200.u3", 0xb0d88720, CART_MUSIC_ROM_SDR_BASE);
    LoadIgs027aIntRom("kov2p_igs027a_china.bin", 0x19a0bd95);
    LoadArmExrom(GAME_KOV2P, "v200_16m.u23", 0x16a0c11f, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x800000;
    gLoadedGameShortName = "kov2p";
    gSimCore.SetGame(GAME_KOV2P);
}

// DoDonPachi II - Bee Storm (World v102).  External ARM ROM is only 0x20000.
static void LoadDdp2()
{
    LoadPgm();
    AddRomZip("ddp2");
    LoadProgRom(GAME_DDP2, "v102.u8", 0x5a9ea040, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("pgm_t1300.u21", 0xe748f0cb, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a1300.u1", 0xfc87a405, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a1301.u2", 0x0c8520da, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_b1300.u7", 0xef646604, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_m1300.u5", 0x82d4015d, CART_MUSIC_ROM_SDR_BASE);
    LoadIgs027aIntRom("ddp2_igs027a_world.bin", 0x3654e20b);
    LoadArmExrom(GAME_DDP2, "v100_210.u23", 0x06c3dd29, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "ddp2";
    gSimCore.SetGame(GAME_DDP2);
}

// Martial Masters (v104).  22 MHz ARM.  Two music ROMs (contiguous in ICS).
static void LoadMartmast()
{
    LoadPgm();
    AddRomZip("martmast");
    LoadProgRom(GAME_MARTMAST, "v104_32m.u9", 0xcfd9dff4, CART_PROG_ROM_SDR_BASE, 0, 0x400000);
    LoadSdramData("pgm_t1000.u3", 0xbbf879b5, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("pgm_a1000.u3", 0x43577ac8, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_a1001.u4", 0xfe7a476f, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_a1002.u6", 0x62e33d38, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("pgm_a1003.u8", 0xb2c4945a, CART_A_ROM_SDR_BASE + 0x1800000);
    LoadSdramData("pgm_a1004.u10", 0x9fd3f5fd, CART_A_ROM_SDR_BASE + 0x2000000);
    LoadSdramData("pgm_b1000.u9", 0xc5961f6f, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_b1001.u11", 0x0b7e1c06, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("pgm_m1000.u5", 0xed407ae8, CART_MUSIC_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("pgm_m1001.u7", 0x662d2d48, CART_MUSIC_ROM_SDR_BASE + 0x0800000);
    LoadIgs027aIntRom("martial_masters_v102_usa.asic", 0xa6c0828c);
    LoadArmExrom(GAME_MARTMAST, "v102_16m.u10", 0x18b745e6, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "martmast";
    gSimCore.SetGame(GAME_MARTMAST);
}

// Dragon World 2001 (Japan).  22 MHz ARM.  Small ROMs.
static void LoadDw2001()
{
    LoadPgm();
    AddRomZip("dw2001");
    LoadProgRom(GAME_DW2001, "dw2001_u22.u22", 0x5cabed92, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramData("dw2001_u11.u11", 0xb27cf093, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("dw2001_u2.u2", 0xd11c733c, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("dw2001_u3.u3", 0x1435aef2, CART_A_ROM_SDR_BASE + 0x0200000);
    LoadSdramData("dw2001_u9.u9", 0xccbca572, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("dw2001_u7.u7", 0x4ea62f21, CART_MUSIC_ROM_SDR_BASE);
    LoadIgs027aIntRom("dw2001_igs027a_japan.bin", 0x3a79159b);
    LoadArmExrom(GAME_DW2001, "dw2001_u12.u12", 0x973db1ab, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x200000;
    gLoadedGameShortName = "dw2001";
    gSimCore.SetGame(GAME_DW2001);
}

// Dragon World Pretty Chance (v110 China).  22 MHz ARM.  Japan internal ROM (BAD_DUMP).
static void LoadDwpc()
{
    LoadPgm();
    AddRomZip("dwpc");
    LoadProgRom(GAME_DWPC, "dwpc_v110cn_u22.u22", 0x64f22362, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramData("dwpc_v110cn_u11.u11", 0xdb219cb8, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("dwpc_v101xx_u2.u2", 0x48b2f407, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("dwpc_v101xx_u3.u3", 0x3bb45a97, CART_A_ROM_SDR_BASE + 0x0200000);
    LoadSdramData("dwpc_v101xx_u9.u9", 0x481b89b1, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("dwpc_v101xx_u7.u7", 0x5cf9bada, CART_MUSIC_ROM_SDR_BASE);
    LoadIgs027aIntRom("dw2001_igs027a_japan.bin", 0x3a79159b);
    // MAME init_dwpc: the only dumped internal ROM is the Japan dw2001 one
    // (BAD_DUMP for the CN dwpc); patch byte 0x3c8 to 0x01 to force the region.
    gSimCore.mDDRMemory->LoadData(std::vector<uint8_t>{0x01}, PROT_INT_ROM_DDR_BASE + 0x3c8, 1);
    LoadArmExrom(GAME_DWPC, "dwpc_v110cn_u12.u12", 0x5bb1ee6a, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x200000;
    gLoadedGameShortName = "dwpc";
    gSimCore.SetGame(GAME_DWPC);
}

// Build the 16KB "dummy" IGS027A internal ARM ROM for dmnfrnt.  The real internal
// ROM is undumped (NO_DUMP in MAME); we synthesize a stub (like MAME's
// pgm_create_dummy_internal_arm_region) that ALSO seeds the shared RAM the way the
// real internal ROM would (shared[0x158]=0x0005 in both chips), then sets SP and
// branches to the external ARM ROM at 0x08000000 (which holds the whole game).
// MUST match the inline <part> bytes in releases/Demon Front (ver. 105).mra.
static std::vector<uint8_t> MakeDmnfrntDummyIntRom()
{
    std::vector<uint8_t> rom(0x4000, 0);
    auto w32 = [&](uint32_t off, uint32_t v) {
        rom[off] = v & 0xff; rom[off + 1] = (v >> 8) & 0xff;
        rom[off + 2] = (v >> 16) & 0xff; rom[off + 3] = (v >> 24) & 0xff;
    };
    // fill with BX lr (e12fff1e) everywhere
    for (uint32_t off = 0; off < 0x4000; off += 4) w32(off, 0xe12fff1e);
    // reset stub (ARM): seed shared[0x158]=5 in both chips, then jump to exrom.
    static const uint32_t stub[] = {
        0xe3a00438, // MOV r0,#0x38000000  (ARM shared window base)
        0xe3a01005, // MOV r1,#5
        0xe5801158, // STR r1,[r0,#0x158]  (current bank; ram_sel resets to 1)
        0xe3a02440, // MOV r2,#0x40000000
        0xe3a03000, // MOV r3,#0
        0xe5823018, // STR r3,[r2,#0x18]   (ram_sel=0)
        0xe5801158, // STR r1,[r0,#0x158]  (other bank)
        0xe3a03001, // MOV r3,#1
        0xe5823018, // STR r3,[r2,#0x18]   (ram_sel=1, restore)
        0xe3a0d410, // MOV sp,#0x10000000
        0xe38ddc04, // ORR sp,sp,#0x400    (sp=0x10000400)
        0xe3a00680, // MOV r0,#0x08000000
        0xe12fff10, // BX r0
    };
    for (uint32_t k = 0; k < sizeof(stub) / 4; k++) w32(4 * k, stub[k]);
    return rom;
}

// ARM cache stress test loaded as the internal ROM (see sim/cachetest_arm.s).
// Self-consistency checker for the three DDR caches: it checksums the external ROM
// (arm_rom_cache) and internal ROM (prot_cache) three ways each and writes+reads a
// pattern through iram (ram_cache); a pattern-dependent cache bug makes the results
// disagree.  Result lands in ARM r0..r5 (read via dbg_rN), then it spins at `done`.
//   r0 = fail flags (bit0 ext, bit1 int, bit2 iram; 0 = pass)
//   r1 = ext fwd checksum   r2 = int fwd checksum
//   r3 = iram first-fail idx (0xffffffff = none)  r4 = iram got  r5 = iram expected
static std::vector<uint8_t> MakeDmnfrntCacheTest()
{
    static const uint32_t code[] = {
        0xe3a0b000, 0xe3a00302, 0xe3a0c902, 0xe3a02000, 0xe3a03000, 0xe7904003,
        0xe0822004, 0xe2833004, 0xe153000c, 0xbafffffa, 0xe1a0a002, 0xe3a02000,
        0xe1a0300c, 0xe2433004, 0xe7904003, 0xe0822004, 0xe3530000, 0xcafffffa,
        0xe152000a, 0x138bb001, 0xe3a02000, 0xe3a05000, 0xe1a03005, 0xe7904003,
        0xe0822004, 0xe2833020, 0xe153000c, 0xbafffffa, 0xe2855004, 0xe3550020,
        0xbafffff6, 0xe152000a, 0x138bb001, 0xe3a00000, 0xe3a0c901, 0xe3a02000,
        0xe3a03000, 0xe7904003, 0xe0822004, 0xe2833004, 0xe153000c, 0xbafffffa,
        0xe1a09002, 0xe3a02000, 0xe1a0300c, 0xe2433004, 0xe7904003, 0xe0822004,
        0xe3530000, 0xcafffffa, 0xe1520009, 0x138bb002, 0xe3a02000, 0xe3a05000,
        0xe1a03005, 0xe7904003, 0xe0822004, 0xe2833020, 0xe153000c, 0xbafffffa,
        0xe2855004, 0xe3550020, 0xbafffff6, 0xe1520009, 0x138bb002, 0xe3a00306,
        0xe59f1084, 0xe3a0c902, 0xe3a03000, 0xe0814123, 0xe7804003, 0xe2833004,
        0xe153000c, 0xbafffffa, 0xe3e08000, 0xe3a05000, 0xe1a03005, 0xe0814123,
        0xe7902003, 0xe1520004, 0x1a000006, 0xe2833020, 0xe153000c, 0xbafffff8,
        0xe2855004, 0xe3550020, 0xbafffff4, 0xea000005, 0xe3780001, 0x01a08123,
        0x01a07002, 0x01a06004, 0xe38bb004, 0xeafffff2, 0xe1a0000b, 0xe1a0100a,
        0xe1a02009, 0xe1a03008, 0xe1a04007, 0xe1a05006, 0xeafffffe, 0xc0de0000,
    };
    std::vector<uint8_t> rom(0x4000, 0);
    auto w32 = [&](uint32_t off, uint32_t v) {
        rom[off] = v & 0xff; rom[off + 1] = (v >> 8) & 0xff;
        rom[off + 2] = (v >> 16) & 0xff; rom[off + 3] = (v >> 24) & 0xff;
    };
    for (uint32_t off = 0; off < 0x4000; off += 4) w32(off, 0xe12fff1e); // BX lr fill
    for (uint32_t k = 0; k < sizeof(code) / 4; k++) w32(4 * k, code[k]);
    return rom;
}

// Demon Front (V105).  IGS027A type3 (55857G), 22 MHz.  68k program plaintext;
// external ARM ROM encrypted (pgm_dfront_decrypt).  Internal ROM undumped -> use
// the synthesized dummy stub that jumps straight into the external ARM ROM.
static void LoadDmnfrnt()
{
    LoadPgm();
    AddRomZip("dmnfrnt");
    LoadProgRom(GAME_DMNFRNT, "v105_16m.u5", 0xbda083bd, CART_PROG_ROM_SDR_BASE, 0, 0x200000);
    LoadSdramData("igs_t04501w064.u29", 0x900eaaac, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("igs_a04501w064.u3", 0x9741bea6, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_a04502w064.u4", 0xe104f405, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_a04503w064.u6", 0xbfd5cfe3, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("igs_b04501w064.u9", 0x29320b7d, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_b04502w016.u11", 0x578c00e9, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_w04501b064.u5", 0x3ab58137, CART_MUSIC_ROM_SDR_BASE);
    // synthesized dummy internal ARM ROM (real one is undumped).  With
    // PGM_CACHETEST set, load the ARM cache stress test instead (tests the DDR
    // caches directly; the game itself will not boot in this mode).
    gSimCore.mDDRMemory->LoadData(
        getenv("PGM_CACHETEST") ? MakeDmnfrntCacheTest() : MakeDmnfrntDummyIntRom(),
        PROT_INT_ROM_DDR_BASE, 1);
    LoadArmExrom(GAME_DMNFRNT, "v105_32m.u26", 0xc798c2ef, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "dmnfrnt";
    gSimCore.SetGame(GAME_DMNFRNT);
}

// IGS027A type3 internal-ROM "execute-only area" (first 0x188 bytes), which is
// NO_DUMP on real hardware.  Reconstructed exactly as MAME does in
// pgm_create_dummy_internal_arm_region_theglad(): a reset vector + FIQ vector into
// the external ARM ROM (0x08000010 theglad / 0x08000038 svg) plus stack/SR setup
// and the soft-reset/jump-table stubs at 0xe8/0xfc/0x110/0x150/0x184.  The rest of
// the internal ROM (0x188..0x3fff) is the real dumped body.
static const uint8_t kThegladEoArea[0x188] = {
    0x0a,0x00,0x00,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0x00,0xf0,0x9f,0xe5,
    0x10,0x00,0x00,0x08,0x10,0x00,0x00,0x08,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xd2,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x01,0x40,0xa0,0xe3,0x06,0x4b,0x84,0xe2,
    0xfa,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd1,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0xf6,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd7,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0xff,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xdb,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0x40,0x41,0xc4,0xe1,0xfe,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x01,0x4a,0xa0,0xe3,0x01,0x0b,0xa0,0xe3,0x04,0xd8,0x80,0xe0,
    0x0f,0x5a,0xa0,0xe3,0x08,0x00,0xa0,0xe3,0x05,0x88,0x80,0xe0,0x10,0x00,0xa0,0xe3,
    0x00,0x00,0xc8,0xe5,0x05,0x78,0xa0,0xe1,0x01,0x6a,0xa0,0xe3,0x12,0x00,0xa0,0xe3,
    0x02,0x0a,0x80,0xe2,0x06,0x68,0x80,0xe0,0x00,0x60,0x87,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x01,0x40,0xa0,0xe3,0x06,0x4b,0x84,0xe2,0xf2,0x0c,0xa0,0xe3,
    0x04,0xd8,0x80,0xe0,0x13,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x28,0x00,0x00,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0x04,0xe0,0x2d,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x04,0xe0,0x9d,0xe4,0x1e,0xff,0x2f,0xe1,0x04,0xe0,0x2d,0xe5,
    0x13,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x04,0xe0,0x9d,0xe4,0x1e,0xff,0x2f,0xe1,
    0xd1,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0xb8,0xd0,0x9f,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0xb0,0xd0,0x9f,0xe5,0xb8,0x10,0x9f,0xe5,0x00,0x00,0xa0,0xe3,
    0x00,0x00,0x81,0xe5,0x02,0xf3,0xa0,0xe3,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0x1e,0xff,0x2f,0xe1,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0x5c,0x10,0x9f,0xe5,
};

// svg EO area (is_svg=1 variant: FIQ vector -> external 0x08000038, soft-reset jump
// loaded from a literal).  Same reconstruction as theglad otherwise.
static const uint8_t kSvgEoArea[0x188] = {
    0x0a,0x00,0x00,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0x00,0xf0,0x9f,0xe5,
    0x38,0x00,0x00,0x08,0x38,0x00,0x00,0x08,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xd2,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x01,0x40,0xa0,0xe3,0x06,0x4b,0x84,0xe2,
    0xfa,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd1,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0xf6,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd7,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0xff,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xdb,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,
    0x40,0x41,0xc4,0xe1,0xfe,0x0c,0xa0,0xe3,0x04,0xd8,0x80,0xe0,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x01,0x4a,0xa0,0xe3,0x01,0x0b,0xa0,0xe3,0x04,0xd8,0x80,0xe0,
    0x0f,0x5a,0xa0,0xe3,0x08,0x00,0xa0,0xe3,0x05,0x88,0x80,0xe0,0x10,0x00,0xa0,0xe3,
    0x00,0x00,0xc8,0xe5,0x05,0x78,0xa0,0xe1,0x01,0x6a,0xa0,0xe3,0x12,0x00,0xa0,0xe3,
    0x02,0x0a,0x80,0xe2,0x06,0x68,0x80,0xe0,0x00,0x60,0x87,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x01,0x40,0xa0,0xe3,0x06,0x4b,0x84,0xe2,0xf2,0x0c,0xa0,0xe3,
    0x04,0xd8,0x80,0xe0,0x13,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x28,0x00,0x00,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0x04,0xe0,0x2d,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0x04,0xe0,0x9d,0xe4,0x1e,0xff,0x2f,0xe1,0x04,0xe0,0x2d,0xe5,
    0x13,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0x04,0xe0,0x9d,0xe4,0x1e,0xff,0x2f,0xe1,
    0xd1,0x00,0xa0,0xe3,0x00,0xf0,0x21,0xe1,0xb8,0xd0,0x9f,0xe5,0xd3,0x00,0xa0,0xe3,
    0x00,0xf0,0x21,0xe1,0xb0,0xd0,0x9f,0xe5,0xb8,0x10,0x9f,0xe5,0x00,0x00,0xa0,0xe3,
    0x00,0x00,0x81,0xe5,0xb0,0xf0,0x9f,0xe5,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0x1e,0xff,0x2f,0xe1,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,0xfe,0xff,0xff,0xea,
    0xfe,0xff,0xff,0xea,0x5c,0x10,0x9f,0xe5,
};

// Build the 16KB IGS027A internal ROM image: synthesized EO area (0x0..0x187)
// followed by the real dumped internal-ROM body at 0x188.
static std::vector<uint8_t> MakeType3IntRom(const uint8_t *eo, const std::vector<uint8_t> &body)
{
    std::vector<uint8_t> rom(0x4000, 0);
    for (uint32_t i = 0; i < 0x188; i++) rom[i] = eo[i];
    for (size_t i = 0; i < body.size() && (0x188 + i) < 0x4000; i++) rom[0x188 + i] = body[i];
    return rom;
}

// The Gladiator (V107 external / V101 68k).  IGS027A type3 (55857G), 22 MHz.  68k
// program plaintext; external ARM ROM encrypted (pgm_theglad_decrypt).  Internal
// ROM real (mostly dumped) at 0x188 + synthesized 0x188 EO area.
static void LoadTheglad()
{
    LoadPgm();
    AddRomZip("theglad");
    LoadProgRom(GAME_THEGLAD, "v101_u6.u6", 0xf799e866, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramData("igs_t04601w64m.u33", 0xe5dab371, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("igs_a04601w64m.u2", 0xd9b2e004, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_a04602w64m.u4", 0x14f22308, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_a04603w64m.u6", 0x8f621e17, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("igs_b04601w64m.u11", 0xee72bccf, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_b04602w32m.u12", 0x7dba9c38, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_w04601b64m.u1", 0x5f15ddb3, CART_MUSIC_ROM_SDR_BASE);
    std::vector<uint8_t> body;
    if (LoadFileByNameOrCrc("theglad_igs027a_v100_overseas.bin", 0x02fe6f52, body))
        gSimCore.mDDRMemory->LoadData(MakeType3IntRom(kThegladEoArea, body), PROT_INT_ROM_DDR_BASE, 1);
    LoadArmExrom(GAME_THEGLAD, "v107_u26.u26", 0xf7c61357, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "theglad";
    gSimCore.SetGame(GAME_THEGLAD);
}

// S.V.G. - Spectral vs Generation (V200).  IGS027A type3 (55857G), 33 MHz.  68k
// plaintext; external ARM ROM (2x4MB) encrypted (pgm_svg_decrypt, no high-byte
// table).  Internal ROM real (mostly dumped) at 0x188 + synthesized EO area.
static void LoadSvg()
{
    LoadPgm();
    AddRomZip("svg");
    LoadProgRom(GAME_SVG, "svg_v200_u30.u30", 0x34c18f3f, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramData("igs_t05601w016.u29", 0x03e110dc, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("igs_a05601w064.u3", 0xea6453e4, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_a05602w064.u4", 0x6d00621b, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_a05603w064.u6", 0x7b71c64f, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("igs_a05604w032.u8", 0x9452a567, CART_A_ROM_SDR_BASE + 0x1800000);
    LoadSdramData("igs_b05601w064.u9", 0x35c0a489, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_b05602w064.u11", 0x8aad3f85, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_w05601b064.u5", 0xbfe61a71, CART_MUSIC_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_w05602b032.u7", 0x0685166d, CART_MUSIC_ROM_SDR_BASE + 0x0800000);
    std::vector<uint8_t> body;
    if (LoadFileByNameOrCrc("svg_igs027a_v200_china.bin", 0x72b73169, body))
        gSimCore.mDDRMemory->LoadData(MakeType3IntRom(kSvgEoArea, body), PROT_INT_ROM_DDR_BASE, 1);
    // external ARM ROM: epr.u26 (0..0x3fffff) + epr.u36 (0x400000..0x7fffff),
    // concatenated then decrypted as one 8MB image.
    std::vector<uint8_t> ext, hi;
    if (LoadFileByNameOrCrc("epr.u26", 0x46826ec8, ext) && LoadFileByNameOrCrc("epr.u36", 0xfa5f3901, hi))
    {
        ext.insert(ext.end(), hi.begin(), hi.end());
        DecryptArmExrom(GAME_SVG, ext);
        gSimCore.mDDRMemory->LoadData(ext, CART_ARM_ROM_DDR_BASE, 1);
    }
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "svg";
    gSimCore.SetGame(GAME_SVG);
}

// happy6 gfx/audio ROM descramble (MAME pgm_descramble_happy6 + _2): two pure
// address permutations applied to each 8MB ROM.  The RTL twin is the
// happy6_scramble_addr() write-address permutation in rtl/rom_loader.sv.
static void DescrambleHappy6(std::vector<uint8_t> &src)
{
    std::vector<uint8_t> buffer(0x800000);
    size_t w = 0;
    for (size_t j = 0; j < 0x800; j += 0x200)
        for (size_t i = j; i < 0x800000; i += 0x800)
        {
            memcpy(&buffer[w], &src[i], 0x200);
            w += 0x200;
        }
    w = 0;
    for (size_t k = 0; k < 0x800000; k += 0x100000)
        for (size_t j = 0; j < 0x40000; j += 0x10000)
            for (size_t i = j; i < 0x100000; i += 0x40000)
            {
                memcpy(&src[w], &buffer[i + k], 0x10000);
                w += 0x10000;
            }
}

static bool LoadSdramDataHappy6(const char *name, uint32_t crc, uint32_t destBase)
{
    std::vector<uint8_t> buffer;
    if (!LoadFileByNameOrCrc(name, crc, buffer))
        return false;
    if (buffer.size() != 0x800000)
    {
        printf("Unexpected size for scrambled ROM %s: 0x%zx\n", name, buffer.size());
        return false;
    }
    DescrambleHappy6(buffer);
    gSimCore.mSDRAM->Write(destBase, static_cast<uint32_t>(buffer.size()), buffer.data());
    printf("Loaded %zu bytes (descrambled) from %s to SDRAM 0x%08X\n", buffer.size(), name, destBase);
    return true;
}

static void LoadKillbldp()
{
    LoadPgm();
    AddRomZip("killbldp");
    LoadProgRom(GAME_KILLBLDP, "v300xx_u6.u6", 0xb7fb8ec9, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramData("igs_t05701w032.u33", 0x567c714f, CART_TILE_ROM_SDR_BASE);
    LoadSdramData("igs_a05701w064.u3", 0x8c0c992c, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_a05702w064.u4", 0x7e5b0f27, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_a05703w064.u6", 0xaccbdb44, CART_A_ROM_SDR_BASE + 0x1000000);
    LoadSdramData("igs_b05701w064.u9", 0xa20cdcef, CART_B_ROM_SDR_BASE + 0x0000000);
    LoadSdramData("igs_b05702w016.u11", 0xfe7457df, CART_B_ROM_SDR_BASE + 0x0800000);
    LoadSdramData("igs_w05701b032.u5", 0x2d3ae593, CART_MUSIC_ROM_SDR_BASE);
    // Internal ARM ROM is a complete 16KB dump (incl. the execute-only area,
    // sourced from a bootleg) - loaded as-is, no synthesis needed.
    std::vector<uint8_t> irom;
    if (LoadFileByNameOrCrc("killbldp_igs027a_alt.bin", 0x98316b06, irom))
        gSimCore.mDDRMemory->LoadData(irom, PROT_INT_ROM_DDR_BASE, 1);
    LoadArmExrom(GAME_KILLBLDP, "v300xx_u26.u26", 0x144388c8, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "killbldp";
    gSimCore.SetGame(GAME_KILLBLDP);
}

// Huanle Liuhe Yi / Happy 6-in-1 (M68K V101, ARM V102CN).  IGS027A type3
// (55857G), 24 MHz.  68k program plaintext; external ARM ROM encrypted
// (pgm_happy6_decrypt); gfx/audio ROMs address-scrambled; internal ROM real
// body at 0x188 + synthesized theglad-style EO area.
static void LoadHappy6()
{
    LoadPgm();
    AddRomZip("happy6");
    LoadProgRom(GAME_HAPPY6, "s101xx_u5.u5", 0xaa4646e3, CART_PROG_ROM_SDR_BASE, 0, 0x80000);
    LoadSdramDataHappy6("t01w64m_u29.u29", 0x2d3feb8b, CART_TILE_ROM_SDR_BASE);
    LoadSdramDataHappy6("a01w64m_u5.u5", 0xbbaa3df3, CART_A_ROM_SDR_BASE + 0x0000000);
    LoadSdramDataHappy6("a02w64m_u6.u6", 0xf8c9cd36, CART_A_ROM_SDR_BASE + 0x0800000);
    LoadSdramDataHappy6("b01w64m_u19.u19", 0x73f5f225, CART_B_ROM_SDR_BASE);
    LoadSdramDataHappy6("w01w64m_u17.u17", 0x7e23e2be, CART_MUSIC_ROM_SDR_BASE);
    std::vector<uint8_t> body;
    if (LoadFileByNameOrCrc("happy6_igs027a_v100_china.bin", 0xed530445, body))
        gSimCore.mDDRMemory->LoadData(MakeType3IntRom(kThegladEoArea, body), PROT_INT_ROM_DDR_BASE, 1);
    LoadArmExrom(GAME_HAPPY6, "v-102cn_u26.u26", 0x310510fb, CART_ARM_ROM_DDR_BASE);
    gSimCore.mTop->rootp->sim_top__DOT__cart_present = 1;
    gSimCore.mTop->rootp->sim_top__DOT__cart_prog_base = 0x100000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_tile_base = 0x180000;
    gSimCore.mTop->rootp->sim_top__DOT__cart_music_base = 0x400000;
    gLoadedGameShortName = "happy6";
    gSimCore.SetGame(GAME_HAPPY6);
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
    case GAME_KOV2P:
        LoadKov2p();
        break;
    case GAME_DDP2:
        LoadDdp2();
        break;
    case GAME_MARTMAST:
        LoadMartmast();
        break;
    case GAME_DW2001:
        LoadDw2001();
        break;
    case GAME_DWPC:
        LoadDwpc();
        break;
    case GAME_DMNFRNT:
        LoadDmnfrnt();
        break;
    case GAME_THEGLAD:
        LoadTheglad();
        break;
    case GAME_SVG:
        LoadSvg();
        break;
    case GAME_KET:
        LoadKet();
        break;
    case GAME_ESPGAL:
        LoadEspgal();
        break;
    case GAME_DDP3:
        LoadDdp3();
        break;
    case GAME_KILLBLDP:
        LoadKillbldp();
        break;
    case GAME_HAPPY6:
        LoadHappy6();
        break;
    case GAME_DWEX:
        LoadDwex();
        break;
    case GAME_PUZZLI2:
        LoadPuzzli2();
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

    if (!LoadPgmEntry(buffer, "romP", romP, CART_PROG_ROM_SDR_BASE, /*swap16=*/true))
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
