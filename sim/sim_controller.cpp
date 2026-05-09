#include "sim_controller.h"

#include <algorithm>
#include <cstring>
#include <set>
#include <sstream>

#include "file_search.h"
#include "gfx_cache.h"
#include "games.h"
#include "imgui_wrap.h"
#include "sim_ddr.h"
#include "sim_hierarchy.h"
#include "sim_state.h"
#include "sim_video.h"
#include "testrom_gui.h"

#include "PGM.h"
#include "PGM___024root.h"
#include "verilated.h"

#include "vltstd/vpi_user.h"

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

const char *VpiTypeToKind(PLI_INT32 type)
{
    switch (type)
    {
    case vpiModule:
        return "module";
    case vpiReg:
        return "reg";
    case vpiNet:
        return "net";
    case vpiMemoryWord:
        return "memory_word";
    default:
        return "signal";
    }
}

uint64_t GetWideBits(const VlWide<8> &wide, int lsb, int width)
{
    uint64_t value = 0;
    for (int bit = 0; bit < width; bit++)
    {
        int absoluteBit = lsb + bit;
        uint32_t word = wide[absoluteBit / 32];
        if ((word >> (absoluteBit % 32)) & 1u)
        {
            value |= (uint64_t{1} << bit);
        }
    }
    return value;
}

void CollectVpiSignalsRecursive(vpiHandle moduleHandle, std::vector<SignalInfo> &signals, std::set<std::string> &seen)
{
    if (moduleHandle == nullptr)
        return;

    if (vpiHandle regIter = vpi_iterate(vpiReg, moduleHandle))
    {
        while (vpiHandle regHandle = vpi_scan(regIter))
        {
            const char *fullName = vpi_get_str(vpiFullName, regHandle);
            if (fullName == nullptr)
                continue;

            std::string name = fullName;
            if (!seen.insert(name).second)
                continue;

            SignalInfo info;
            info.mName = name;
            info.mWidth = std::max(0, vpi_get(vpiSize, regHandle));
            info.mKind = VpiTypeToKind(vpi_get(vpiType, regHandle));
            info.mSource = "vpi";
            signals.push_back(std::move(info));
        }
    }

    if (vpiHandle moduleIter = vpi_iterate(vpiModule, moduleHandle))
    {
        while (vpiHandle childModule = vpi_scan(moduleIter))
        {
            CollectVpiSignalsRecursive(childModule, signals, seen);
        }
    }
}
} // namespace

SimController gSimController;

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
    gSimCore.mTop->joystick_p1 = 0;
    gSimCore.mTop->joystick_p2 = 0;

    mStateManager = new SimState(gSimCore.mTop, gSimCore.mDDRMemory.get(), kStateOffset, kStateSize);

    if (mHeadless)
    {
        gSimCore.mVideo->Init(448, 224, nullptr);
    }
    else
    {
        gSimCore.mVideo->Init(450, 224, ImguiGetRenderer());
        gSimCore.mGfxCache->Init(ImguiGetRenderer(), gSimCore.Memory(MemoryRegion::PALETTE_RAM));
    }

    Verilated::traceEverOn(true);
    gSimCore.mTop->dipswitch = mDipSwitch;

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
    mVpiHandleCache.clear();
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::LoadGame(const std::string &name)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (GameIsPgmFilePath(name.c_str()))
    {
        if (!GameInitPgmFile(name.c_str()))
        {
            return ControllerResult<EmptyResult>::Failure("load_failed", "Failed to load PGM file: " + name);
        }
    }
    else
    {
        Game game = GameFind(name.c_str());
        if (game == GAME_INVALID)
        {
            return ControllerResult<EmptyResult>::Failure("unknown_game", "Unknown game: " + name);
        }

        if (!GameInit(game))
        {
            return ControllerResult<EmptyResult>::Failure("load_failed", "Failed to load game: " + name);
        }
    }

    mStateManager->SetGameName(GameLoadedShortName());
    gSimCore.mTop->dipswitch = mDipSwitch;
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
    gSimCore.mTop->dipswitch = mDipSwitch;
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

    ApplyInputState();
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
        ApplyInputState();
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

        ApplyInputState();
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
        {"BIOS_PROG_ROM", MemoryRegion::BIOS_PROG_ROM}, {"CART_PROG_ROM", MemoryRegion::CART_PROG_ROM},
        {"PALETTE_RAM", MemoryRegion::PALETTE_RAM},     {"VIDEO_RAM", MemoryRegion::VIDEO_RAM},
        {"WORK_RAM", MemoryRegion::WORK_RAM},           {"AUDIO_RAM", MemoryRegion::AUDIO_RAM},
        {"BIOS_TILE_ROM", MemoryRegion::BIOS_TILE_ROM}, {"BIOS_MUSIC_ROM", MemoryRegion::BIOS_MUSIC_ROM},
        {"CART_TILE_ROM", MemoryRegion::CART_TILE_ROM}, {"CART_MUSIC_ROM", MemoryRegion::CART_MUSIC_ROM},
        {"CART_B_ROM", MemoryRegion::CART_B_ROM},       {"CART_A_ROM", MemoryRegion::CART_A_ROM},
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

ControllerResult<EmptyResult> SimController::WriteMemory(const std::string &region, uint32_t address, const std::vector<uint8_t> &data)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    auto regionResult = ParseRegion(region);
    if (!regionResult.ok)
    {
        return ControllerResult<EmptyResult>::Failure(regionResult.errorCode, regionResult.errorMessage);
    }

    gSimCore.Memory(regionResult.value).Write(address, static_cast<uint32_t>(data.size()), data.data());
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<std::vector<std::string>> SimController::ListRegions() const
{
    return ControllerResult<std::vector<std::string>>::Success(
        {"BIOS_ROM", "PROGRAM_ROM", "PALETTE_RAM", "VIDEO_RAM", "WORK_RAM", "AUDIO_RAM", "TILE_ROM", "MUSIC_ROM", "B_ROM", "A_ROM"});
}

ControllerResult<SignalReadResult> SimController::ReadSignal(const std::string &signal) const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<SignalReadResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    return ReadSignalValue(signal);
}

ControllerResult<SignalListResult> SimController::ListSignals() const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<SignalListResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    SignalListResult result;
    result.mSignals.push_back({"vblank", 1, "alias", "builtin"});
    result.mSignals.push_back({"hblank", 1, "alias", "builtin"});
    result.mSignals.push_back({"reset", 1, "alias", "builtin"});
    result.mSignals.push_back({"rom_load_busy", 1, "alias", "builtin"});
    result.mSignals.push_back({"ss_state_out", 32, "alias", "builtin"});

    auto vpiResult = ListSignalsVpi();
    if (!vpiResult.ok)
    {
        return vpiResult;
    }

    result.mSignals.insert(result.mSignals.end(), vpiResult.value.mSignals.begin(), vpiResult.value.mSignals.end());
    std::sort(result.mSignals.begin(), result.mSignals.end(),
              [](const SignalInfo &a, const SignalInfo &b) { return a.mName < b.mName; });
    return ControllerResult<SignalListResult>::Success(result);
}

ControllerResult<EmptyResult> SimController::SetDipSwitch(uint8_t switchIndex, bool enabled)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (switchIndex >= 8)
    {
        return ControllerResult<EmptyResult>::Failure("invalid_dipswitch", "DIP switch index must be 0..7");
    }

    uint8_t mask = static_cast<uint8_t>(1u << switchIndex);
    if (enabled)
        mDipSwitch |= mask;
    else
        mDipSwitch &= static_cast<uint8_t>(~mask);

    gSimCore.mTop->dipswitch = mDipSwitch;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::SetDipSwitches(uint8_t value)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    mDipSwitch = value;
    gSimCore.mTop->dipswitch = mDipSwitch;
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<InputStateResult> SimController::GetInputState() const
{
    InputStateResult result;
    result.mButtons = ImguiGetButtons();
    return ControllerResult<InputStateResult>::Success(result);
}

ControllerResult<uint32_t> SimController::ParseInputBits(const std::string &name) const
{
    if (name == "left")
        return ControllerResult<uint32_t>::Success(0x0002);
    if (name == "right")
        return ControllerResult<uint32_t>::Success(0x0001);
    if (name == "down")
        return ControllerResult<uint32_t>::Success(0x0004);
    if (name == "up")
        return ControllerResult<uint32_t>::Success(0x0008);
    if (name == "button1" || name == "btn1" || name == "a")
        return ControllerResult<uint32_t>::Success(0x0010);
    if (name == "start")
        return ControllerResult<uint32_t>::Success(0x00010000);

    return ControllerResult<uint32_t>::Failure("invalid_input", "Unknown input: " + name);
}

void SimController::ApplyInputState() const
{
    if (!mInitialized)
        return;

    uint32_t buttons = ImguiGetButtons();
    gSimCore.mTop->joystick_p1 = buttons & 0xffff;
    gSimCore.mTop->start = (buttons >> 16) & 0xffff;
}

ControllerResult<EmptyResult> SimController::SetInput(const std::string &name, bool pressed)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    auto bitResult = ParseInputBits(name);
    if (!bitResult.ok)
        return ControllerResult<EmptyResult>::Failure(bitResult.errorCode, bitResult.errorMessage);

    if (pressed)
        ImguiSetButtonBits(bitResult.value);
    else
        ImguiClearButtonBits(bitResult.value);

    ApplyInputState();
    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::ClearInput(const std::string &name)
{
    return SetInput(name, false);
}

ControllerResult<RunResult> SimController::PressInput(const std::string &name)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return ControllerResult<RunResult>::Failure(initResult.errorCode, initResult.errorMessage);

    auto bitResult = ParseInputBits(name);
    if (!bitResult.ok)
        return ControllerResult<RunResult>::Failure(bitResult.errorCode, bitResult.errorMessage);

    RunResult totalResult;

    ImguiSetButtonBits(bitResult.value);
    ApplyInputState();

    auto pressedResult = RunFrames(2);
    if (!pressedResult.ok)
        return pressedResult;
    totalResult.mTicksExecuted += pressedResult.value.mTicksExecuted;
    totalResult.mFramesExecuted += pressedResult.value.mFramesExecuted;
    if (pressedResult.value.mReason != RunStopReason::COMPLETED)
    {
        totalResult.mReason = pressedResult.value.mReason;
        ImguiClearButtonBits(bitResult.value);
        ApplyInputState();
        return ControllerResult<RunResult>::Success(totalResult);
    }

    ImguiClearButtonBits(bitResult.value);
    ApplyInputState();

    auto releasedResult = RunFrames(2);
    if (!releasedResult.ok)
        return releasedResult;
    totalResult.mTicksExecuted += releasedResult.value.mTicksExecuted;
    totalResult.mFramesExecuted += releasedResult.value.mFramesExecuted;
    totalResult.mReason = releasedResult.value.mReason;

    return ControllerResult<RunResult>::Success(totalResult);
}

uint8_t SimController::GetDipSwitches() const
{
    return mDipSwitch;
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

ControllerResult<EmptyResult> SimController::StartAudioCapture(const std::string &filename)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    if (!gSimCore.StartAudioCapture(filename.c_str()))
    {
        return ControllerResult<EmptyResult>::Failure("audio_capture_failed", "Failed to start audio capture: " + filename);
    }

    return ControllerResult<EmptyResult>::Success({});
}

ControllerResult<EmptyResult> SimController::StopAudioCapture()
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
        return initResult;

    gSimCore.StopAudioCapture();
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

ControllerResult<GuiStateResult> SimController::GetGuiState() const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<GuiStateResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    GuiStateResult result;
    TestRomGuiState guiState = GetTestRomGuiWindow().GetState();
    result.mAvailable = guiState.mAvailable;
    result.mAddress = guiState.mAddress;
    result.mLastSyncTicks = guiState.mLastSyncTicks;
    result.mEntries.reserve(guiState.mEntries.size());
    for (const auto &entry : guiState.mEntries)
    {
        GuiEntryState out;
        out.mIndex = entry.mIndex;
        out.mLabel = entry.mLabel;
        out.mType = entry.mType;
        out.mTypeName = TestRomGuiWindow::TypeName(entry.mType);
        out.mValue = entry.mValue;
        out.mOverrideValue = entry.mOverrideValue;
        result.mEntries.push_back(std::move(out));
    }

    return ControllerResult<GuiStateResult>::Success(result);
}

ControllerResult<Ics2115DebugState> SimController::GetIcs2115DebugState() const
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<Ics2115DebugState>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    auto *root = gSimCore.mTop->rootp;
    Ics2115DebugState result;
    result.mActiveOsc = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__active_osc;
    result.mOscSelect = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__osc_select;
    result.mRegSelect = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__reg_select;
    result.mVmode = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__vmode;
    result.mIrqPending = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__irq_pending;
    result.mIrqEnabled = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__irq_enabled;
    result.mIrqOn = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__irq_on != 0;
    result.mOscIrqPendingCount = 0;
    result.mVolIrqPendingCount = 0;
    result.mStateOnCount = 0;
    result.mStopCount = 0;
    result.mSeqState = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__seq_state;
    result.mSeqVoiceIdx = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__seq_voice_idx;
    result.mSampleTick = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__sample_tick != 0;
    result.mHostDout = root->sim_top__DOT__pgm_inst__DOT__ics2115_dout;
    result.mHostCsN = root->sim_top__DOT__pgm_inst__DOT__ics2115_cs_n != 0;
    result.mHostRdN = root->sim_top__DOT__pgm_inst__DOT__ics2115_rd_n != 0;
    result.mHostWrN = root->sim_top__DOT__pgm_inst__DOT__ics2115_wr_n != 0;
    result.mHostIrq = result.mIrqOn;
    result.mHostReady = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__host_voice_wr_pending == 0;
    result.mResetN = root->sim_top__DOT__pgm_inst__DOT__z80_reset_n != 0;
    result.mRomDataValid = root->sim_top__DOT__pgm_inst__DOT__ics2115_data_valid != 0;
    result.mRomAddr = root->sim_top__DOT__pgm_inst__DOT__ics2115_rom_addr;
    result.mRomData = root->sim_top__DOT__pgm_inst__DOT__ics2115_rom_q;
    result.mAudioLeft = static_cast<int16_t>(root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_left);
    result.mAudioRight = static_cast<int16_t>(root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_right);
    result.mAudioValid = root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_valid != 0;

    result.mTimers.reserve(2);
    for (int i = 0; i < 2; i++)
    {
        Ics2115TimerState timer;
        timer.mPreset = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__timer_preset[i];
        timer.mScale = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__timer_scale[i];
        timer.mCount = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__timer_count[i];
        timer.mPeriod = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__timer_period[i];
        timer.mRunning = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__timer_running[i] != 0;
        result.mTimers.push_back(timer);
    }

    result.mVoices.reserve(32);
    for (int i = 0; i < 32; i++)
    {
        const auto &wide = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__voice_regs[i];
        Ics2115VoiceState voice;
        voice.mIndex = i;
        voice.mStateRamp = GetWideBits(wide, 0, 7);
        voice.mStateOn = GetWideBits(wide, 7, 1) != 0;
        voice.mVolMode = GetWideBits(wide, 8, 8);
        voice.mVolCtrl = GetWideBits(wide, 16, 8);
        voice.mVolPan = GetWideBits(wide, 24, 8);
        voice.mVolIncr = GetWideBits(wide, 32, 8);
        voice.mVolEnd = GetWideBits(wide, 40, 26);
        voice.mVolStart = GetWideBits(wide, 66, 26);
        voice.mVolAcc = GetWideBits(wide, 92, 26);
        voice.mOscCtl = GetWideBits(wide, 118, 8);
        voice.mOscConf = GetWideBits(wide, 126, 8);
        voice.mOscSaddr = GetWideBits(wide, 134, 8);
        voice.mOscEnd = GetWideBits(wide, 142, 29);
        voice.mOscStart = GetWideBits(wide, 171, 29);
        voice.mOscFc = GetWideBits(wide, 200, 16);
        voice.mOscAcc = GetWideBits(wide, 216, 29);

        if (voice.mOscConf & 0x80)
            result.mOscIrqPendingCount++;
        if (voice.mVolCtrl & 0x80)
            result.mVolIrqPendingCount++;
        if (voice.mStateOn)
            result.mStateOnCount++;
        if (voice.mOscConf & 0x02)
            result.mStopCount++;

        result.mVoices.push_back(voice);
    }

    return ControllerResult<Ics2115DebugState>::Success(result);
}

ControllerResult<GuiOverrideResult> SimController::SetGuiOverrideByIndex(uint32_t index, uint16_t value, bool pulse)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<GuiOverrideResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    bool applied = false;
    std::string error;
    if (!GetTestRomGuiWindow().SetOverrideByIndex(index, value, pulse, &applied, &error))
    {
        return ControllerResult<GuiOverrideResult>::Failure("gui_unavailable", error);
    }

    GuiOverrideResult result;
    result.mApplied = applied;
    return ControllerResult<GuiOverrideResult>::Success(result);
}

ControllerResult<GuiOverrideResult> SimController::SetGuiOverrideByLabel(const std::string &label, uint16_t value, bool pulse)
{
    auto initResult = EnsureInitialized();
    if (!initResult.ok)
    {
        return ControllerResult<GuiOverrideResult>::Failure(initResult.errorCode, initResult.errorMessage);
    }

    bool applied = false;
    std::string error;
    if (!GetTestRomGuiWindow().SetOverrideByLabel(label, value, pulse, &applied, &error))
    {
        return ControllerResult<GuiOverrideResult>::Failure("gui_unavailable", error);
    }

    GuiOverrideResult result;
    result.mApplied = applied;
    return ControllerResult<GuiOverrideResult>::Success(result);
}

ControllerResult<SignalReadResult> SimController::ReadSignalValue(const std::string &signal) const
{
    auto builtinResult = ReadSignalValueBuiltin(signal);
    if (builtinResult.ok)
    {
        return builtinResult;
    }

    return ReadSignalValueVpi(signal);
}

ControllerResult<SignalReadResult> SimController::ReadSignalValueBuiltin(const std::string &signal) const
{
    SignalReadResult result;
    result.mSignal = signal;
    result.mWidth = 1;

    if (signal == "vblank")
    {
        result.mValue = gSimCore.mTop->vblank;
    }
    else if (signal == "hblank")
    {
        result.mValue = gSimCore.mTop->hblank;
    }
    else if (signal == "reset")
    {
        result.mValue = gSimCore.mTop->reset;
    }
    else if (signal == "rom_load_busy")
    {
        result.mValue = gSimCore.mTop->rootp->sim_top__DOT__rom_load_busy;
    }
    else if (signal == "ss_state_out")
    {
        result.mValue = gSimCore.mTop->ss_state_out;
        result.mWidth = 32;
    }
    else
    {
        return ControllerResult<SignalReadResult>::Failure("invalid_signal", "Unknown built-in signal: " + signal);
    }

    std::ostringstream valueHex;
    valueHex << std::hex << result.mValue;
    result.mValueHex = valueHex.str();
    return ControllerResult<SignalReadResult>::Success(result);
}

vpiHandle SimController::LookupVpiHandle(const std::string &signal) const
{
    auto it = mVpiHandleCache.find(signal);
    if (it != mVpiHandleCache.end())
    {
        return it->second;
    }

    const std::string candidates[] = {
        signal,
        signal.rfind("TOP.", 0) == 0 ? signal : "TOP." + signal,
        signal.rfind("sim_top.", 0) == 0 ? signal : "sim_top." + signal,
        signal.rfind("TOP.", 0) == 0 || signal.rfind("sim_top.", 0) == 0 ? signal : "TOP.sim_top." + signal,
    };

    for (const auto &candidate : candidates)
    {
        vpiHandle handle = vpi_handle_by_name(const_cast<PLI_BYTE8 *>(candidate.c_str()), nullptr);
        if (handle != nullptr)
        {
            mVpiHandleCache[signal] = handle;
            return handle;
        }
    }

    return nullptr;
}

ControllerResult<SignalReadResult> SimController::ReadSignalValueVpi(const std::string &signal) const
{
    vpiHandle handle = LookupVpiHandle(signal);
    if (handle == nullptr)
    {
        return ControllerResult<SignalReadResult>::Failure(
            "invalid_signal", "Unknown signal: " + signal + " (also tried TOP." + signal + ")");
    }

    int width = vpi_get(vpiSize, handle);
    if (width <= 0)
    {
        return ControllerResult<SignalReadResult>::Failure("signal_read_failed", "Failed to determine signal width: " + signal);
    }
    if (width > 64)
    {
        return ControllerResult<SignalReadResult>::Failure("signal_too_wide", "Signal is wider than 64 bits: " + signal);
    }

    s_vpi_value value;
    value.format = vpiHexStrVal;
    vpi_get_value(handle, &value);
    if (value.value.str == nullptr)
    {
        return ControllerResult<SignalReadResult>::Failure("signal_read_failed", "Failed to read signal value: " + signal);
    }

    std::string valueHex = value.value.str;
    for (char c : valueHex)
    {
        if (c == 'x' || c == 'X' || c == 'z' || c == 'Z')
        {
            return ControllerResult<SignalReadResult>::Failure("signal_has_unknown_bits", "Signal has X/Z bits: " + signal);
        }
    }

    uint64_t parsedValue = 0;
    std::stringstream stream;
    stream << std::hex << valueHex;
    stream >> parsedValue;
    if (stream.fail())
    {
        return ControllerResult<SignalReadResult>::Failure("signal_read_failed", "Failed to parse signal value: " + signal);
    }

    SignalReadResult result;
    result.mSignal = signal;
    result.mValue = parsedValue;
    result.mWidth = static_cast<uint32_t>(width);
    result.mValueHex = valueHex;
    return ControllerResult<SignalReadResult>::Success(result);
}

ControllerResult<SignalListResult> SimController::ListSignalsVpi() const
{
    SignalListResult result;
    std::set<std::string> seen;

    vpiHandle moduleIter = vpi_iterate(vpiModule, nullptr);
    if (moduleIter == nullptr)
    {
        return ControllerResult<SignalListResult>::Failure("signal_list_failed", "Failed to enumerate VPI modules");
    }

    while (vpiHandle moduleHandle = vpi_scan(moduleIter))
    {
        CollectVpiSignalsRecursive(moduleHandle, result.mSignals, seen);
    }

    return ControllerResult<SignalListResult>::Success(result);
}

bool SimController::EvaluateCondition(const Condition &condition) const
{
    switch (condition.mType)
    {
    case Condition::Type::SIGNAL_EQUALS:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue == condition.mValue;
    }
    case Condition::Type::SIGNAL_NOT_EQUALS:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue != condition.mValue;
    }
    case Condition::Type::SIGNAL_LESS_THAN:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue < condition.mValue;
    }
    case Condition::Type::SIGNAL_LESS_EQUAL:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue <= condition.mValue;
    }
    case Condition::Type::SIGNAL_GREATER_THAN:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue > condition.mValue;
    }
    case Condition::Type::SIGNAL_GREATER_EQUAL:
    {
        auto signalResult = ReadSignalValue(condition.mSignal);
        return signalResult.ok && signalResult.value.mValue >= condition.mValue;
    }
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
