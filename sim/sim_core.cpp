
#include "sim_core.h"
#include "games.h"
#include "sim_hierarchy.h"
#include "PGM.h"
#include "PGM___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include "sim_sdram.h"
#include "sim_ddr.h"
#include "sim_video.h"
#include "gfx_cache.h"
#include "m68k.h"

#include <cstring>
#include <cstdio>

// Global instance
SimCore gSimCore;

// SimCore implementation
SimCore::SimCore()
    : mVideo(nullptr), mTop(nullptr), mDDRMemory(nullptr), mSDRAM(nullptr), mContextp(nullptr), mTotalTicks(0), mTraceActive(false),
      mTraceDepth(1), mSimulationRun(false), mSimulationStep(false), mSimulationStepSize(100000), mSimulationStepVblank(false),
      mSystemPause(false), mSimulationWpSet(false), mSimulationWpAddr(0)
{
    strcpy(mTraceFilename, "sim.fst");

}

SimCore::~SimCore()
{
    Shutdown();
}

#define unique_memory_16b(instance, size)                                                                                                  \
    std::make_unique<Memory16b>(mTop->rootp->PGM_SIGNAL(instance, ram_l).m_storage, mTop->rootp->PGM_SIGNAL(instance, ram_h).m_storage, size)

#define unique_memory_8b(instance, size) std::make_unique<Memory8b>(mTop->rootp->PGM_SIGNAL(instance, ram).m_storage, size)

#define unique_memory_8b_2(instance1, instance2, size)                                                                                     \
    std::make_unique<Memory8b>(mTop->rootp->PGM_SIGNAL(instance1, instance2, ram).m_storage, size)

void SimCore::Init()
{
    mContextp = new VerilatedContext;
    mTop = new PGM{mContextp};
    mTfp = nullptr;

    for( int i = 0; i < (int)MemoryRegion::COUNT; i++ )
    {
        SetMemory((MemoryRegion)i, std::make_unique<MemoryNull>());
    }

    // Create memory subsystems
    mSDRAM = std::make_unique<SimSDRAM>(128 * 1024 * 1024);
    mDDRMemory = std::make_unique<SimDDR>(0x30000000, 256 * 1024 * 1024);
    mVideo = std::make_unique<SimVideo>();

    mGfxCache = std::make_unique<GfxCache>();

    SetMemory(MemoryRegion::WORK_RAM, unique_memory_16b(work_ram, 128 * 1024));
    SetMemory(MemoryRegion::AUDIO_RAM, unique_memory_16b(aram, 64 * 1024));
    SetMemory(MemoryRegion::VIDEO_RAM, unique_memory_16b(vram, 64 * 1024));
    SetMemory(MemoryRegion::PALETTE_RAM, unique_memory_8b(palram, 32 * 1024));
    SetMemory(MemoryRegion::BIOS_ROM, std::make_unique<MemorySlice>(*mSDRAM, CPU_ROM_SDR_BASE, 1024 * 1024));
    SetMemory(MemoryRegion::TILE_ROM, std::make_unique<MemorySlice>(*mSDRAM, TILE_ROM_SDR_BASE, 16 * 1024 * 1024));

    // Initialize M68K CPU wrapper
    mCPU = std::make_unique<M68K>();
    mCPU->MapMemory(0x00000000, 0xfe000000, Memory(MemoryRegion::BIOS_ROM));
}

void SimCore::Tick(int count)
{
    for (int i = 0; i < count; i++)
    {
        mTotalTicks++;

        mSDRAM->update_channel_64(0, 1, mTop->sdr_addr, mTop->sdr_req, mTop->sdr_rw, mTop->sdr_be, mTop->sdr_data, &mTop->sdr_q, &mTop->sdr_ack);
        mVideo->clock(mTop->ce_pixel != 0, mTop->hblank != 0, mTop->vblank != 0, mTop->red, mTop->green, mTop->blue);

        mDDRMemory->clock(mTop->ddr_addr, mTop->ddr_wdata, mTop->ddr_rdata, mTop->ddr_read, mTop->ddr_write, mTop->ddr_busy,
                          mTop->ddr_read_complete, mTop->ddr_burstcnt, mTop->ddr_byteenable);

        mContextp->timeInc(1);
        mTop->clk = 0;

        mTop->eval();
        if (mTfp)
            mTfp->dump(mContextp->time());

        mContextp->timeInc(1);
        mTop->clk = 1;

        mTop->eval();
        if (mTfp)
            mTfp->dump(mContextp->time());

        if (mSimulationWpSet && mTop->rootp->PGM_SIGNAL(cpu_word_addr) == mSimulationWpAddr)
        {
            mSimulationRun = false;
            mSimulationStep = false;
            return;
        }
    }
}

void SimCore::TickUntil(std::function<bool()> until)
{
    while (!until())
    {
        Tick(1);
    }
}

void SimCore::Shutdown()
{
    if (mTfp)
    {
        mTfp->close();
        mTfp.reset();
    }

    if (mTop)
    {
        mTop->final();
        delete mTop;
        mTop = nullptr;
    }

    if (mContextp)
    {
        delete mContextp;
        mContextp = nullptr;
    }

    // Reset member objects
    mSDRAM.reset();
    mDDRMemory.reset();
    mVideo.reset();
}

void SimCore::StartTrace(const char *filename, int depth)
{
    if (!mContextp || !mTop)
        return;

    if (mTfp)
    {
        mTfp->close();
        mTfp.reset();
    }

    strcpy(mTraceFilename, filename);
    mTraceDepth = depth;

    mTfp = std::make_unique<VerilatedFstC>();
    mTop->trace(mTfp.get(), mTraceDepth);
    mTfp->open(mTraceFilename);
    mTraceActive = true;
}

void SimCore::StopTrace()
{
    if (mTfp)
    {
        mTfp->close();
        mTfp.reset();
    }
    mTraceActive = false;
}

bool SimCore::SendIOCTLData(uint8_t index, const std::vector<uint8_t> &data)
{
    if (!mTop)
    {
        return false;
    }

    printf("Starting ioctl download (index=%d, size=%zu)\n", (int)index, data.size());

    // Start download sequence
    mTop->reset = 1;
    mTop->ioctl_download = 1;
    mTop->ioctl_index = index;
    mTop->ioctl_wr = 0;
    mTop->ioctl_addr = 0;
    mTop->ioctl_dout = 0;

    // Clock to let the core see download start
    Tick(1);

    // Send each byte
    for (size_t i = 0; i < data.size(); i++)
    {
        // Set up data and address
        mTop->ioctl_addr = i;
        mTop->ioctl_dout = data[i];
        mTop->ioctl_wr = 1;

        // Clock and wait for ready
        Tick(1);
        WaitForIOCTLReady();

        // Deassert write
        mTop->ioctl_wr = 0;
        Tick(1);

        // Progress indicator every 64KB
        if ((i & 0xFFFF) == 0)
        {
            printf("  Sent %zu/%zu bytes\n", i, data.size());
        }
    }

    // End download sequence
    mTop->ioctl_download = 0;
    mTop->reset = 0;
    Tick(1);

    printf("ioctl download complete\n");
    return true;
}

bool SimCore::SendIOCTLDataDDR(uint8_t index, uint32_t addr, const std::vector<uint8_t> &data)
{
    printf("Starting DDR ioctl download (index=%d, size=%zu, addr=%08x)\n", (int)index, data.size(), addr);

    mDDRMemory->load_data(data, addr, 1);
    mTop->reset = 1;
    mTop->ioctl_download = 1;
    mTop->ioctl_index = index;
    mTop->ioctl_wr = 0;
    mTop->ioctl_addr = data.size();
    mTop->ioctl_dout = 0;

    Tick(1);

    mTop->ioctl_download = 0;
    Tick(2);

    TickUntil([&] { return mTop->rootp->sim_top__DOT__rom_load_busy == 0; });

    mTop->reset = 0;

    printf("ioctl download complete\n");
    return true;
}

void SimCore::WaitForIOCTLReady()
{
    int timeout = 1000; // Prevent infinite loops

    while (mTop->ioctl_wait && timeout > 0)
    {
        Tick(1);
        timeout--;
    }

    if (timeout == 0)
    {
        printf("Warning: ioctl_wait timeout\n");
    }
}

void SimCore::SetGame(game_t game)
{
    mTop->rootp->sim_top__DOT__board_cfg = game << 8;
}

game_t SimCore::GetGame() const
{
    return (game_t)(mTop->rootp->sim_top__DOT__board_cfg >> 8);
}

const char *SimCore::GetGameName() const
{
    return game_name(GetGame());
}
