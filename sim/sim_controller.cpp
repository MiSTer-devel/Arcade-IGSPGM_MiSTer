#include "sim_controller.h"

#include <algorithm>
#include <cstring>

#include "file_search.h"
#include "gfx_cache.h"
#include "games.h"
#include "imgui_wrap.h"
#include "sim_ddr.h"
#include "sim_hierarchy.h"
#include "sim_state.h"
#include "sim_video.h"

#include "PGM.h"
#include "PGM___024root.h"
#include "verilated.h"

namespace
{
constexpr int kStateOffset = 0x3E000000;
constexpr int kStateSize = 512 * 1024;

const char *RunStopReasonToString(RunStopReason reason)
{
    switch (reason)
    {
    case RunStopReason::COMPLETED:
        return "completed";
    case RunStopReason::CONDITION_MET:
        return "condition_met";
    case RunStopReason::WATCHPOINT_HIT:
        return "watchpoint_hit";
    case RunStopReason::TIMEOUT:
        return "timeout";
    case RunStopReason::ERROR:
        return "error";
    }
    return "error";
}
} // namespace

ControllerResult<EmptyResult> SimController::EnsureInitialized() const
{
    if (!mInitialized)
    {
        return ControllerResult<EmptyResult>::Failure("not_initialized", "Simulator is not initialized");
    }
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::Initialize(bool headless)
{
    if (mInitialized)
    {
        return ControllerResult<EmptyResult>::Success({});
    }

    mHeadless = headless;

    gSimCore.Init();
    gFileSearch.AddSearchPath(".");

    gSimCore.mTop->ss_do_save = 0;
    gSimCore.mTop->ss_do_restore = 0;
    gSimCore.mTop->obj_debug_idx = -1;
    gSimCore.mTop->joystick_p1 = 0;
    gSimCore.mTop->joystick_p2 = 0;

    mStateManager = new SimState(gSimCore.mTop, gSimCore.mDDRMemory.get(), kStateOffset, kStateSize);

    if (mHeadless)
    {
        gSimCore.mVideo->Init(448, 224, nullptr);
    }
    else
    {
        gSimCore.mVideo->Init(448, 224, ImguiGetRenderer());
        gSimCore.mGfxCache->Init(ImguiGetRenderer(), gSimCore.Memory(MemoryRegion::PALETTE_RAM));
    }

    Verilated::traceEverOn(true);
    gSimCore.mTop->dswa = mDipSwitchA;
    gSimCore.mTop->dswb = mDipSwitchB;

    mInitialized = true;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::Shutdown()
{
    if (mStateManager)
    {
        delete mStateManager;
        mStateManager = nullptr;
    }

    if (mInitialized)
    {
        gSimCore.Shutdown();
    }

    mInitialized = false;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::LoadGame(const std::string &name)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    Game game = GameFind(name.c_str());
    if (game == GAME_INVALID)
    {
        return ControllerResult<EmptyResult>::Failure("unknown_game", "Unknown game: " + name);
    }

    if (!GameInit(game))
    {
        return ControllerResult<EmptyResult>::Failure("load_failed", "Failed to load game: " + name);
    }

    mStateManager->SetGameName(name.c_str());
    gSimCore.mTop->dswa = mDipSwitchA;
    gSimCore.mTop->dswb = mDipSwitchB;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::LoadMra(const std::string &path)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (!GameInitMra(path.c_str()))
    {
        return ControllerResult<EmptyResult>::Failure("load_failed", "Failed to load MRA: " + path);
    }

    mStateManager->SetGameName(gSimCore.GetGameName());
    gSimCore.mTop->dswa = mDipSwitchA;
    gSimCore.mTop->dswb = mDipSwitchB;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::Reset(uint64_t cycles)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    gSimCore.mTop->reset = 1;
    gSimCore.Tick(cycles);
    gSimCore.mTop->reset = 0;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<RunResult> SimController::RunCycles(uint64_t cycles)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<RunResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    TickResult tickResult = gSimCore.Tick(static_cast<int>(cycles));
    RunResult runResult;
    runResult.mReason = ConvertTickStopReason(tickResult.mReason);
    runResult.mTicksExecuted = tickResult.mTicksExecuted;
    return ControllerResult<RunResult>::Success(runResult);
}

ControllerResult<RunResult> SimController::RunFrames(uint64_t frames)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<RunResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    RunResult runResult;
    for (uint64_t i = 0; i < frames; i++)
    {
        TickResult lowResult = gSimCore.TickUntil([&] { return gSimCore.mTop->vblank == 0; }, 10000000);
        runResult.mTicksExecuted += lowResult.mTicksExecuted;
        if (!lowResult.Succeeded())
        {
            runResult.mReason = ConvertTickStopReason(lowResult.mReason);
            return ControllerResult<RunResult>::Success(runResult);
        }

        TickResult highResult = gSimCore.TickUntil([&] { return gSimCore.mTop->vblank != 0; }, 10000000);
        runResult.mTicksExecuted += highResult.mTicksExecuted;
        if (!highResult.Succeeded())
        {
            runResult.mReason = ConvertTickStopReason(highResult.mReason);
            return ControllerResult<RunResult>::Success(runResult);
        }

        runResult.mFramesExecuted++;
    }

    runResult.mReason = RunStopReason::COMPLETED;
    return ControllerResult<RunResult>::Success(runResult);
}

ControllerResult<RunResult> SimController::RunUntil(const RunUntilRequest &request)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<RunResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    if (EvaluateCondition(request.mCondition))
    {
        RunResult result;
        result.mReason = RunStopReason::CONDITION_MET;
        return ControllerResult<RunResult>::Success(result);
    }

    uint64_t ticks = 0;
    while (true)
    {
        if (request.mTimeoutCycles > 0 && ticks >= request.mTimeoutCycles)
        {
            RunResult result;
            result.mReason = RunStopReason::TIMEOUT;
            result.mTicksExecuted = ticks;
            return ControllerResult<RunResult>::Success(result);
        }

        TickResult tickResult = gSimCore.Tick(1);
        ticks += tickResult.mTicksExecuted;
        if (tickResult.mReason != TickStopReason::COMPLETED)
        {
            RunResult result;
            result.mReason = ConvertTickStopReason(tickResult.mReason);
            result.mTicksExecuted = ticks;
            return ControllerResult<RunResult>::Success(result);
        }

        if (EvaluateCondition(request.mCondition))
        {
            RunResult result;
            result.mReason = RunStopReason::CONDITION_MET;
            result.mTicksExecuted = ticks;
            return ControllerResult<RunResult>::Success(result);
        }
    }
}

ControllerResult<SimStatus> SimController::GetStatus() const
{
    SimStatus status;
    status.mInitialized = mInitialized;
    status.mRunning = gSimCore.mSimulationRun;
    status.mPaused = gSimCore.mSystemPause;
    status.mTraceActive = gSimCore.IsTraceActive();
    status.mHeadless = mHeadless;
    status.mTotalTicks = gSimCore.GetTotalTicks();
    status.mGameName = mInitialized ? gSimCore.GetGameName() : "";
    return ControllerResult<SimStatus>::Success(status);
}

ControllerResult<CpuState> SimController::GetCpuState() const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<CpuState>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    CpuState state;
    state.mPc = gSimCore.mCPU->GetPC();

    M68KRegisters regs = gSimCore.mCPU->GetRegisters();
    state.mRegisters.assign(std::begin(regs.r), std::end(regs.r));

    const M68KInstruction &inst = gSimCore.mCPU->GetInstruction(state.mPc);
    state.mDisasm = inst.mDisasm;
    return ControllerResult<CpuState>::Success(state);
}

ControllerResult<MemoryRegion> SimController::ParseRegion(const std::string &name) const
{
    static const std::vector<std::pair<std::string, MemoryRegion>> kRegions = {
        {"BIOS_ROM", MemoryRegion::BIOS_ROM},       {"PROGRAM_ROM", MemoryRegion::PROGRAM_ROM},
        {"PALETTE_RAM", MemoryRegion::PALETTE_RAM}, {"VIDEO_RAM", MemoryRegion::VIDEO_RAM},
        {"WORK_RAM", MemoryRegion::WORK_RAM},       {"AUDIO_RAM", MemoryRegion::AUDIO_RAM},
        {"TILE_ROM", MemoryRegion::TILE_ROM},       {"MUSIC_ROM", MemoryRegion::MUSIC_ROM},
        {"B_ROM", MemoryRegion::B_ROM},             {"A_ROM", MemoryRegion::A_ROM},
    };

    for (const auto &entry : kRegions)
    {
        if (entry.first == name)
        {
            return ControllerResult<MemoryRegion>::Success(entry.second);
        }
    }

    return ControllerResult<MemoryRegion>::Failure("invalid_region", "Unknown memory region: " + name);
}

ControllerResult<MemoryReadResult> SimController::ReadMemory(const std::string &region, uint32_t address, uint32_t size) const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<MemoryReadResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    auto regionResult = ParseRegion(region);
    if (!regionResult.ok)
    {
        return ControllerResult<MemoryReadResult>::Failure(regionResult.errorCode, regionResult.errorMessage);
    }

    MemoryReadResult result;
    result.mRegion = region;
    result.mAddress = address;
    result.mData.resize(size);
    gSimCore.Memory(regionResult.value).Read(address, size, result.mData.data());
    return ControllerResult<MemoryReadResult>::Success(result);
}

ControllerResult<std::vector<std::string>> SimController::ListRegions() const
{
    return ControllerResult<std::vector<std::string>>::Success(
        {"BIOS_ROM", "PROGRAM_ROM", "PALETTE_RAM", "VIDEO_RAM", "WORK_RAM", "AUDIO_RAM", "TILE_ROM", "MUSIC_ROM", "B_ROM", "A_ROM"});
}

ControllerResult<EmptyResult> SimController::SetDipSwitchA(uint8_t value)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    mDipSwitchA = value;
    gSimCore.mTop->dswa = mDipSwitchA;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::SetDipSwitchB(uint8_t value)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    mDipSwitchB = value;
    gSimCore.mTop->dswb = mDipSwitchB;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<StateListResult> SimController::ListStates() const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<StateListResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    StateListResult result;
    result.mStates = mStateManager->GetPgmstateFiles();
    return ControllerResult<StateListResult>::Success(result);
}

ControllerResult<EmptyResult> SimController::SaveState(const std::string &filename)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (!mStateManager->SaveState(filename.c_str()))
    {
        return ControllerResult<EmptyResult>::Failure("save_state_failed", "Failed to save state: " + filename);
    }
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::LoadState(const std::string &filename)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (!mStateManager->RestoreState(filename.c_str()))
    {
        return ControllerResult<EmptyResult>::Failure("load_state_failed", "Failed to load state: " + filename);
    }
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::StartTrace(const std::string &filename, int depth)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    gSimCore.StartTrace(filename.c_str(), depth);
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::StopTrace()
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    gSimCore.StopTrace();
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<ScreenshotResult> SimController::SaveScreenshot(const std::string &path)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<ScreenshotResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    gSimCore.mVideo->UpdateTexture();
    if (!gSimCore.mVideo->SaveScreenshot(path.c_str()))
    {
        return ControllerResult<ScreenshotResult>::Failure("screenshot_failed", "Failed to save screenshot: " + path);
    }

    ScreenshotResult result;
    result.mPath = path;
    return ControllerResult<ScreenshotResult>::Success(result);
}

uint64_t SimController::ReadSignalValue(const std::string &signal) const
{
    if (signal == "vblank")
        return gSimCore.mTop->vblank;
    if (signal == "hblank")
        return gSimCore.mTop->hblank;
    if (signal == "reset")
        return gSimCore.mTop->reset;
    if (signal == "rom_load_busy")
        return gSimCore.mTop->rootp->sim_top__DOT__rom_load_busy;
    if (signal == "ss_state_out")
        return gSimCore.mTop->ss_state_out;
    return 0;
}

bool SimController::EvaluateCondition(const Condition &condition) const
{
    switch (condition.mType)
    {
    case Condition::Type::SIGNAL_EQUALS:
        return ReadSignalValue(condition.mSignal) == condition.mValue;
    case Condition::Type::SIGNAL_NOT_EQUALS:
        return ReadSignalValue(condition.mSignal) != condition.mValue;
    case Condition::Type::CPU_PC_EQUALS:
        return gSimCore.mCPU->GetPC() == condition.mValue;
    case Condition::Type::CPU_PC_IN_RANGE:
    {
        uint32_t pc = gSimCore.mCPU->GetPC();
        return pc >= condition.mValue && pc < condition.mValue2;
    }
    case Condition::Type::CPU_PC_OUT_OF_RANGE:
    {
        uint32_t pc = gSimCore.mCPU->GetPC();
        return pc < condition.mValue || pc >= condition.mValue2;
    }
    case Condition::Type::AND:
        for (const auto &child : condition.mChildren)
        {
            if (!EvaluateCondition(child))
                return false;
        }
        return true;
    case Condition::Type::OR:
        for (const auto &child : condition.mChildren)
        {
            if (EvaluateCondition(child))
                return true;
        }
        return false;
    case Condition::Type::NOT:
        return !condition.mChildren.empty() && !EvaluateCondition(condition.mChildren[0]);
    }
    return false;
}

RunStopReason SimController::ConvertTickStopReason(TickStopReason reason) const
{
    switch (reason)
    {
    case TickStopReason::COMPLETED:
        return RunStopReason::COMPLETED;
    case TickStopReason::WATCHPOINT_HIT:
        return RunStopReason::WATCHPOINT_HIT;
    case TickStopReason::CONDITION_MET:
        return RunStopReason::CONDITION_MET;
    case TickStopReason::TIMEOUT:
        return RunStopReason::TIMEOUT;
    }
    return RunStopReason::ERROR;
}
