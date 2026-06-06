
#ifndef SIM_CORE_H
#define SIM_CORE_H

#include <functional>
#include <memory>
#include <vector>
#include <cstdint>
#include <deque>

#include "games.h"
#include "sim_memory.h"

class VerilatedContext;
class PGM;
class VerilatedFstC;
class SimSDRAM;
class SimDDR;
class SimVideo;
class GfxCache;
class M68K;
class SimAudioCapture;

enum class MemoryRegion : int
{
    BIOS_PROG_ROM,
    CART_PROG_ROM,
    PALETTE_RAM,
    VIDEO_RAM,
    WORK_RAM,
    AUDIO_RAM,
    BIOS_TILE_ROM,
    BIOS_MUSIC_ROM,
    CART_TILE_ROM,
    CART_MUSIC_ROM,
    CART_B_ROM,
    CART_A_ROM,
    PROT_RAM,

    COUNT
};

enum class TickStopReason
{
    COMPLETED,
    WATCHPOINT_HIT,
    CONDITION_MET,
    TIMEOUT
};

struct TickResult
{
    TickStopReason mReason;
    int mTicksExecuted;

    bool Succeeded() const
    {
        return mReason == TickStopReason::COMPLETED || mReason == TickStopReason::CONDITION_MET;
    }
};

class SimCore
{
  public:
    // Public members that external code needs access to
    PGM *mTop;
    std::unique_ptr<SimVideo> mVideo;
    std::unique_ptr<SimDDR> mDDRMemory;
    std::unique_ptr<SimSDRAM> mSDRAM;

    std::unique_ptr<GfxCache> mGfxCache;
    std::unique_ptr<M68K> mCPU;
    std::unique_ptr<SimAudioCapture> mAudioCapture;

    // Simulation state (made public for compatibility)
    uint64_t mTotalTicks;
    bool mSimulationRun;
    bool mSimulationStep;
    int mSimulationStepSize;
    bool mSimulationStepVblank;
    bool mSystemPause;
    bool mSimulationWpSet;
    int mSimulationWpAddr;
    bool mTraceActive;
    char mTraceFilename[64];
    int mTraceDepth;

    // Constructor/Destructor
    SimCore();
    ~SimCore();

    // Main simulation methods
    void Init();
    TickResult Tick(int count = 1);
    TickResult TickUntil(std::function<bool()> until, int limit);
    void Shutdown();
    void SetSignalWatchpointCallback(std::function<bool()> callback);

    // Trace control methods
    void StartTrace(const char *filename, int depth = 1);
    void StopTrace();
    bool IsTraceActive() const
    {
        return mTraceActive;
    }

    // Audio capture control methods
    bool StartAudioCapture(const char *filename, uint64_t simClockHz = 50'000'000ull);
    void StopAudioCapture();
    bool IsAudioCaptureActive() const;

    // PicoROM/debug-link emulator for simulator-side TestROM control.
    void DebugLinkStart(uint32_t commsWordAddr = 0x1F800);
    void DebugLinkStop();
    bool DebugLinkEnabled() const;
    bool DebugLinkWrite(const std::vector<uint8_t> &data, uint64_t timeoutCyclesPerByte = 2000000);
    std::vector<uint8_t> DebugLinkRead(uint32_t maxBytes, uint32_t minBytes = 0, uint64_t timeoutCycles = 2000000);

    // IOCTL methods
    bool SendIOCTLData(uint8_t index, const std::vector<uint8_t> &data);
    bool SendIOCTLDataDDR(uint8_t index, uint32_t addr, const std::vector<uint8_t> &data);

    // Stats
    uint64_t GetTotalTicks() const
    {
        return mTotalTicks;
    }

    void SetGame(Game game);
    Game GetGame() const;
    const char *GetGameName() const;

    MemoryInterface &Memory(MemoryRegion region)
    {
        return *mMemoryRegion[(int)region];
    }

  private:
    // Verilator context and top module
    VerilatedContext *mContextp;
    std::unique_ptr<VerilatedFstC> mTfp;
    std::function<bool()> mSignalWatchpointCallback;

    std::unique_ptr<MemoryInterface> mMemoryRegion[(int)MemoryRegion::COUNT];

    bool mDebugLinkEnabled = false;
    uint32_t mDebugLinkBaseByte = 0;
    uint8_t mDebugLinkInSeq = 0;
    uint8_t mDebugLinkOutSeq = 0;
    bool mDebugLinkPrevInByteRead = false;
    bool mDebugLinkPrevOutRead = false;
    bool mDebugLinkInByteReadPulse = false;
    bool mDebugLinkTxOutstanding = false;
    std::deque<uint8_t> mDebugLinkTx;
    std::deque<uint8_t> mDebugLinkRx;

    TickResult TickOneCycle();
    void DebugLinkTick();
    void DebugLinkPrimeTx();
    void DebugLinkWriteByte(uint32_t offset, uint8_t value);

    // IOCTL helper methods
    void WaitForIOCTLReady();

    void SetMemory(MemoryRegion region, std::unique_ptr<MemoryInterface> &&memory)
    {
        mMemoryRegion[(int)region].swap(memory);
    }
};

// Global instance
extern SimCore gSimCore;

#endif // SIM_CORE_H
