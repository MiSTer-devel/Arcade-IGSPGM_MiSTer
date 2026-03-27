
#ifndef SIM_CORE_H
#define SIM_CORE_H

#include <functional>
#include <memory>
#include <vector>
#include <cstdint>

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

enum class MemoryRegion : int
{
    BIOS_ROM,
    PROGRAM_ROM,
    PALETTE_RAM,
    VIDEO_RAM,
    WORK_RAM,
    AUDIO_RAM,
    TILE_ROM,

    COUNT
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
    void Tick(int count = 1);
    void TickUntil(std::function<bool()> until);
    void Shutdown();

    // Trace control methods
    void StartTrace(const char *filename, int depth = 1);
    void StopTrace();
    bool IsTraceActive() const
    {
        return mTraceActive;
    }

    // IOCTL methods
    bool SendIOCTLData(uint8_t index, const std::vector<uint8_t> &data);
    bool SendIOCTLDataDDR(uint8_t index, uint32_t addr, const std::vector<uint8_t> &data);

    // Stats
    uint64_t GetTotalTicks() const
    {
        return mTotalTicks;
    }

    void SetGame(game_t game);
    game_t GetGame() const;
    const char *GetGameName() const;

    MemoryInterface &Memory(MemoryRegion region)
    {
        return *mMemoryRegion[(int)region];
    }

  private:
    // Verilator context and top module
    VerilatedContext *mContextp;
    std::unique_ptr<VerilatedFstC> mTfp;

    std::unique_ptr<MemoryInterface> mMemoryRegion[(int)MemoryRegion::COUNT];

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
