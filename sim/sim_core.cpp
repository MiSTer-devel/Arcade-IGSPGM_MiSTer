
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
#include "sim_audio_capture.h"
#include "sim_ics2115_ui.h"
#include "testrom_gui.h"
#include "gfx_cache.h"
#include "m68k.h"

#include <cstring>
#include <cstdio>
#include <algorithm>

// Global instance
SimCore gSimCore;

namespace
{
bool gPrevVblank = false;
constexpr uint32_t DEBUG_LINK_ROM_MASK = (1024 * 1024) - 1;
constexpr uint32_t DEBUG_LINK_ACTIVE_V_OFF = 5;
constexpr uint32_t DEBUG_LINK_PENDING_V_OFF = 9;
constexpr uint32_t DEBUG_LINK_IN_SEQ_V_OFF = 13;
constexpr uint32_t DEBUG_LINK_OUT_SEQ_V_OFF = 17;
constexpr uint32_t DEBUG_LINK_IN_BYTE_V_OFF = 1025;
constexpr uint32_t DEBUG_LINK_OUT_AREA_OFF = 1536;
}

// SimCore implementation
SimCore::SimCore()
    : mVideo(nullptr), mTop(nullptr), mDDRMemory(nullptr), mSDRAM(nullptr), mContextp(nullptr), mTotalTicks(0), mTraceActive(false),
      mTraceDepth(1), mSimulationRun(false), mSimulationStep(false), mSimulationStepSize(100000), mSimulationStepVblank(false),
      mSystemPause(false), mSimulationWpSet(false), mSimulationWpAddr(0), mSignalWatchpointCallback()
{
    strcpy(mTraceFilename, "sim.fst");

}

SimCore::~SimCore()
{
    Shutdown();
}

#define UNIQUE_MEMORY_16B(instance, size)                                                                                                   \
    std::make_unique<Memory16b>(mTop->rootp->PGM_SIGNAL(instance, ram_l).m_storage, mTop->rootp->PGM_SIGNAL(instance, ram_h).m_storage, size)

#define UNIQUE_MEMORY_8B(instance, size) std::make_unique<Memory8b>(mTop->rootp->PGM_SIGNAL(instance, ram).m_storage, size)

#define UNIQUE_MEMORY_8B_2(instance1, instance2, size)                                                                                      \
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
    mAudioCapture = std::make_unique<SimAudioCapture>();
    mDebugLinkEnabled = false;
    mDebugLinkBaseByte = 0;
    mDebugLinkInSeq = 0;
    mDebugLinkOutSeq = 0;
    mDebugLinkPrevInByteRead = false;
    mDebugLinkPrevOutRead = false;
    mDebugLinkInByteReadPulse = false;
    mDebugLinkTxOutstanding = false;
    mDebugLinkTx.clear();
    mDebugLinkRx.clear();
    Ics2115DebugUiReset();
    GetTestRomGuiWindow().Reset();
    gPrevVblank = false;

    SetMemory(MemoryRegion::WORK_RAM, UNIQUE_MEMORY_16B(work_ram, 128 * 1024));
    SetMemory(MemoryRegion::AUDIO_RAM, UNIQUE_MEMORY_16B(aram, 64 * 1024));
    SetMemory(MemoryRegion::VIDEO_RAM, UNIQUE_MEMORY_8B(vram, 32 * 1024));
    SetMemory(MemoryRegion::PALETTE_RAM, UNIQUE_MEMORY_16B(palram, 8 * 1024));
    SetMemory(MemoryRegion::BIOS_PROG_ROM, std::make_unique<MemorySlice>(*mSDRAM, BIOS_PROG_ROM_SDR_BASE, 1024 * 1024));
    SetMemory(MemoryRegion::CART_PROG_ROM, std::make_unique<MemorySlice>(*mSDRAM, CART_PROG_ROM_SDR_BASE, 16 * 1024 * 1024));
    SetMemory(MemoryRegion::BIOS_TILE_ROM, std::make_unique<MemorySlice>(*mSDRAM, BIOS_TILE_ROM_SDR_BASE, 2 * 1024 * 1024));
    SetMemory(MemoryRegion::BIOS_MUSIC_ROM, std::make_unique<MemorySlice>(*mSDRAM, BIOS_MUSIC_ROM_SDR_BASE, 2 * 1024 * 1024));
    SetMemory(MemoryRegion::CART_TILE_ROM, std::make_unique<MemorySlice>(*mSDRAM, CART_TILE_ROM_SDR_BASE, 32 * 1024 * 1024));
    SetMemory(MemoryRegion::CART_MUSIC_ROM, std::make_unique<MemorySlice>(*mSDRAM, CART_MUSIC_ROM_SDR_BASE, 32 * 1024 * 1024));
    SetMemory(MemoryRegion::CART_B_ROM, std::make_unique<MemorySlice>(*mSDRAM, CART_B_ROM_SDR_BASE, 64 * 1024 * 1024));
    // IGS022 shared protection RAM (0x300000-0x303fff): split hi/lo byte arrays.
    SetMemory(MemoryRegion::PROT_RAM, std::make_unique<Memory16b>(
        mTop->rootp->PGM_SIGNAL(igs022, sharedram_lo, ram).m_storage,
        mTop->rootp->PGM_SIGNAL(igs022, sharedram_hi, ram).m_storage,
        16 * 1024));

    // Initialize M68K CPU wrapper
    mCPU = std::make_unique<M68K>();
    mCPU->MapMemory(0x00000000, 0xfe000000, Memory(MemoryRegion::BIOS_PROG_ROM)); // TODO
}

TickResult SimCore::TickOneCycle()
{
    mTotalTicks++;

    mSDRAM->UpdateChannel64(0, mTop->sdr_addr, mTop->sdr_req, mTop->sdr_rw, mTop->sdr_be, mTop->sdr_data, &mTop->sdr_q, &mTop->sdr_ack);
    mVideo->Clock(mTop->ce_pixel != 0, mTop->hblank != 0, mTop->vblank != 0, mTop->red, mTop->green, mTop->blue);

    mDDRMemory->Clock(mTop->ddr_addr, mTop->ddr_wdata, mTop->ddr_rdata, mTop->ddr_read, mTop->ddr_write, mTop->ddr_busy,
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

    if (mAudioCapture)
    {
        mAudioCapture->Tick(mTotalTicks,
                            mTop->rootp->PGM_SIGNAL(ics2115_audio_valid) != 0,
                            static_cast<int16_t>(mTop->rootp->PGM_SIGNAL(ics2115_audio_left)),
                            static_cast<int16_t>(mTop->rootp->PGM_SIGNAL(ics2115_audio_right)));
    }
    Ics2115DebugUiTick();
    DebugLinkTick();

    const bool vblank = mTop->vblank != 0;
    if (vblank && !gPrevVblank)
    {
        GetTestRomGuiWindow().TickVblank();
    }
    gPrevVblank = vblank;

    if (mSimulationWpSet && mTop->rootp->PGM_SIGNAL(cpu_word_addr) == mSimulationWpAddr)
    {
        mSimulationRun = false;
        mSimulationStep = false;
        return {TickStopReason::WATCHPOINT_HIT, 1};
    }

    if (mSignalWatchpointCallback && mSignalWatchpointCallback())
    {
        mSimulationRun = false;
        mSimulationStep = false;
        return {TickStopReason::WATCHPOINT_HIT, 1};
    }

    return {TickStopReason::COMPLETED, 1};
}

void SimCore::DebugLinkWriteByte(uint32_t offset, uint8_t value)
{
    if (!mDebugLinkEnabled)
        return;
    Memory(MemoryRegion::BIOS_PROG_ROM).Write((mDebugLinkBaseByte + offset) & DEBUG_LINK_ROM_MASK, 1, &value);
}

void SimCore::DebugLinkStart(uint32_t commsWordAddr)
{
    // The PicoROM API names the 68000 ROM word address.  The TestROM reads
    // this through the normal program-ROM bus, so the simulator emulates
    // PicoROM by patching the BIOS ROM slice and watching CPU ROM reads.
    mDebugLinkBaseByte = (commsWordAddr << 1) & DEBUG_LINK_ROM_MASK;
    mDebugLinkEnabled = true;
    mDebugLinkInSeq = 0;
    mDebugLinkOutSeq = 0;
    mDebugLinkPrevInByteRead = false;
    mDebugLinkPrevOutRead = false;
    mDebugLinkInByteReadPulse = false;
    mDebugLinkTxOutstanding = false;
    mDebugLinkTx.clear();
    mDebugLinkRx.clear();

    const uint8_t magic[4] = {'I', 'P', 'O', 'C'};
    Memory(MemoryRegion::BIOS_PROG_ROM).Write(mDebugLinkBaseByte, sizeof(magic), magic);
    DebugLinkWriteByte(DEBUG_LINK_ACTIVE_V_OFF, 1);
    DebugLinkWriteByte(DEBUG_LINK_PENDING_V_OFF, 0);
    DebugLinkWriteByte(DEBUG_LINK_IN_SEQ_V_OFF, mDebugLinkInSeq);
    DebugLinkWriteByte(DEBUG_LINK_OUT_SEQ_V_OFF, mDebugLinkOutSeq);
    DebugLinkWriteByte(DEBUG_LINK_IN_BYTE_V_OFF, 0);
}

void SimCore::DebugLinkStop()
{
    if (mDebugLinkEnabled)
        DebugLinkWriteByte(DEBUG_LINK_ACTIVE_V_OFF, 0);
    mDebugLinkEnabled = false;
    mDebugLinkPrevInByteRead = false;
    mDebugLinkPrevOutRead = false;
    mDebugLinkInByteReadPulse = false;
    mDebugLinkTxOutstanding = false;
    mDebugLinkTx.clear();
    mDebugLinkRx.clear();
}

bool SimCore::DebugLinkEnabled() const
{
    return mDebugLinkEnabled;
}

void SimCore::DebugLinkPrimeTx()
{
    if (!mDebugLinkEnabled || mDebugLinkTxOutstanding || mDebugLinkTx.empty())
        return;
    const uint8_t value = mDebugLinkTx.front();
    mDebugLinkTx.pop_front();
    DebugLinkWriteByte(DEBUG_LINK_IN_BYTE_V_OFF, value);
    mDebugLinkInSeq++;
    DebugLinkWriteByte(DEBUG_LINK_IN_SEQ_V_OFF, mDebugLinkInSeq);
    mDebugLinkTxOutstanding = true;
}

void SimCore::DebugLinkTick()
{
    if (!mDebugLinkEnabled || !mTop)
        return;

    const uint32_t byteAddr = mTop->rootp->PGM_SIGNAL(cpu_word_addr) & DEBUG_LINK_ROM_MASK;
    const uint8_t ds = mTop->rootp->PGM_SIGNAL(address_translator, cpu_ds_n);
    const bool lowByte = (ds & 1) == 0;
    const bool highByte = (ds & 2) == 0;

    const uint32_t inByteAddr = (mDebugLinkBaseByte + DEBUG_LINK_IN_BYTE_V_OFF) & ~1u;
    const bool inByteRead = lowByte && (byteAddr == inByteAddr);
    if (inByteRead && !mDebugLinkPrevInByteRead)
    {
        mDebugLinkInByteReadPulse = true;
        if (mDebugLinkTxOutstanding)
            mDebugLinkTxOutstanding = false;
        DebugLinkPrimeTx();
    }
    mDebugLinkPrevInByteRead = inByteRead;

    const uint32_t outAreaByte = (mDebugLinkBaseByte + DEBUG_LINK_OUT_AREA_OFF) & DEBUG_LINK_ROM_MASK;
    const bool outRead = (lowByte || highByte) && (byteAddr >= outAreaByte) && (byteAddr < outAreaByte + 512) && (((byteAddr - outAreaByte) & 1u) == 0);
    if (outRead && !mDebugLinkPrevOutRead)
    {
        const uint8_t value = static_cast<uint8_t>((byteAddr - outAreaByte) >> 1);
        mDebugLinkRx.push_back(value);
        mDebugLinkOutSeq++;
        DebugLinkWriteByte(DEBUG_LINK_OUT_SEQ_V_OFF, mDebugLinkOutSeq);
    }
    mDebugLinkPrevOutRead = outRead;
}

bool SimCore::DebugLinkWrite(const std::vector<uint8_t> &data, uint64_t timeoutCyclesPerByte)
{
    if (!mDebugLinkEnabled)
        DebugLinkStart();

    for (uint8_t value : data)
        mDebugLinkTx.push_back(value);
    DebugLinkPrimeTx();

    const uint64_t timeoutCycles = timeoutCyclesPerByte * std::max<size_t>(data.size(), 1);
    uint64_t elapsed = 0;
    while (!mDebugLinkTx.empty() || mDebugLinkTxOutstanding)
    {
        if (timeoutCycles && elapsed >= timeoutCycles)
            return false;
        TickResult tickResult = Tick(64);
        elapsed += tickResult.mTicksExecuted;
        if (!tickResult.Succeeded())
            return false;
    }
    return true;
}

std::vector<uint8_t> SimCore::DebugLinkRead(uint32_t maxBytes, uint32_t minBytes, uint64_t timeoutCycles)
{
    if (!mDebugLinkEnabled)
        DebugLinkStart();
    if (minBytes > maxBytes)
        minBytes = maxBytes;

    uint64_t elapsed = 0;
    while (mDebugLinkRx.size() < minBytes)
    {
        if (timeoutCycles && elapsed >= timeoutCycles)
            break;
        TickResult tickResult = Tick(64);
        elapsed += tickResult.mTicksExecuted;
        if (!tickResult.Succeeded())
            break;
    }

    const uint32_t count = std::min<uint32_t>(maxBytes, static_cast<uint32_t>(mDebugLinkRx.size()));
    std::vector<uint8_t> out;
    out.reserve(count);
    for (uint32_t i = 0; i < count; i++)
    {
        out.push_back(mDebugLinkRx.front());
        mDebugLinkRx.pop_front();
    }
    return out;
}

TickResult SimCore::Tick(int count)
{
    TickResult result{TickStopReason::COMPLETED, 0};

    for (int i = 0; i < count; i++)
    {
        TickResult tickResult = TickOneCycle();
        result.mTicksExecuted += tickResult.mTicksExecuted;
        if (tickResult.mReason != TickStopReason::COMPLETED)
        {
            result.mReason = tickResult.mReason;
            return result;
        }
    }

    return result;
}

TickResult SimCore::TickUntil(std::function<bool()> until, int limit)
{
    int count = 0;
    while (!until())
    {
        count++;
        if (count == limit)
        {
            return {TickStopReason::TIMEOUT, count - 1};
        }

        TickResult tickResult = Tick(1);
        if (tickResult.mReason != TickStopReason::COMPLETED)
        {
            tickResult.mTicksExecuted = count;
            return tickResult;
        }
    }
    return {TickStopReason::CONDITION_MET, count};
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
    mAudioCapture.reset();
    mSDRAM.reset();
    mDDRMemory.reset();
    mVideo.reset();
    mSignalWatchpointCallback = nullptr;
    Ics2115DebugUiReset();
    GetTestRomGuiWindow().Reset();
    gPrevVblank = false;
}

void SimCore::SetSignalWatchpointCallback(std::function<bool()> callback)
{
    mSignalWatchpointCallback = std::move(callback);
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

bool SimCore::StartAudioCapture(const char *filename, uint64_t simClockHz)
{
    if (!mAudioCapture)
    {
        mAudioCapture = std::make_unique<SimAudioCapture>();
    }
    return mAudioCapture->Start(filename, simClockHz);
}

void SimCore::StopAudioCapture()
{
    if (mAudioCapture)
    {
        mAudioCapture->Stop();
    }
}

bool SimCore::IsAudioCaptureActive() const
{
    return mAudioCapture && mAudioCapture->IsActive();
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

    mDDRMemory->LoadData(data, addr, 1);
    mTop->reset = 1;
    mTop->ioctl_download = 1;
    mTop->ioctl_index = index;
    mTop->ioctl_wr = 0;
    mTop->ioctl_addr = data.size();
    mTop->ioctl_dout = 0;

    Tick(1);

    mTop->ioctl_download = 0;
    Tick(2);

    if (!TickUntil([&] { return mTop->rootp->sim_top__DOT__rom_load_busy == 0; }, 0).Succeeded())
    {
        return false;
    }

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

void SimCore::SetGame(Game game)
{
    mTop->rootp->sim_top__DOT__board_cfg = game << 8;
}

Game SimCore::GetGame() const
{
    return (Game)(mTop->rootp->sim_top__DOT__board_cfg >> 8);
}

const char *SimCore::GetGameName() const
{
    return GameName(GetGame());
}
