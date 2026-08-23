#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "m68k.h"
#include "sim_core.h"
#include "verilated_vpi.h"

class SimState;

template <typename T>
struct ControllerResult
{
    bool ok = false;
    T value{};
    std::string errorCode;
    std::string errorMessage;

    static ControllerResult<T> Success(const T &value)
    {
        ControllerResult<T> result;
        result.ok = true;
        result.value = value;
        return result;
    }

    static ControllerResult<T> Failure(const std::string &code, const std::string &message)
    {
        ControllerResult<T> result;
        result.ok = false;
        result.errorCode = code;
        result.errorMessage = message;
        return result;
    }
};

struct EmptyResult
{
};

struct InputStateResult
{
    uint32_t mButtons = 0;
};

enum class RunStopReason
{
    COMPLETED,
    CONDITION_MET,
    WATCHPOINT_HIT,
    TIMEOUT,
    ERROR
};

struct RunResult
{
    RunStopReason mReason = RunStopReason::COMPLETED;
    uint64_t mTicksExecuted = 0;
    uint64_t mFramesExecuted = 0;
};

struct SimStatus
{
    bool mInitialized = false;
    bool mRunning = false;
    bool mPaused = false;
    bool mTraceActive = false;
    bool mHeadless = false;
    uint64_t mTotalTicks = 0;
    std::string mGameName;
};

struct CpuState
{
    uint32_t mPc = 0;
    std::vector<uint32_t> mRegisters;
    std::string mDisasm;
};

struct MemoryReadResult
{
    std::string mRegion;
    uint32_t mAddress = 0;
    std::vector<uint8_t> mData;
};

struct DebugLinkReadResult
{
    std::vector<uint8_t> mData;
    uint32_t mAvailable = 0;
};

struct SignalReadResult
{
    std::string mSignal;
    uint64_t mValue = 0;
    uint32_t mWidth = 0;
    std::string mValueHex;
};

struct SignalInfo
{
    std::string mName;
    uint32_t mWidth = 0;
    std::string mKind;
    std::string mSource;
};

struct SignalListResult
{
    std::vector<SignalInfo> mSignals;
};

struct ScreenshotResult
{
    std::string mPath;
};

struct FlipResult
{
    bool mFlipX = false;
    bool mFlipY = false;
};

struct GuiEntryState
{
    uint32_t mIndex = 0;
    std::string mLabel;
    uint8_t mType = 0;
    std::string mTypeName;
    uint16_t mValue = 0;
    uint16_t mOverrideValue = 0;
};

struct GuiStateResult
{
    bool mAvailable = false;
    uint32_t mAddress = 0x0A00;
    uint64_t mLastSyncTicks = 0;
    std::vector<GuiEntryState> mEntries;
};

struct GuiOverrideResult
{
    bool mApplied = false;
};

struct Ics2115TimerState
{
    uint8_t mPreset = 0;
    uint8_t mScale = 0;
    uint32_t mCount = 0;
    uint32_t mPeriod = 0;
    bool mRunning = false;
};

struct Ics2115VoiceState
{
    uint32_t mIndex = 0;
    uint32_t mOscAcc = 0;
    uint16_t mOscFc = 0;
    uint32_t mOscStart = 0;
    uint32_t mOscEnd = 0;
    uint8_t mOscSaddr = 0;
    uint8_t mOscConf = 0;
    uint8_t mOscCtl = 0;
    uint32_t mVolAcc = 0;
    uint32_t mVolStart = 0;
    uint32_t mVolEnd = 0;
    uint8_t mVolIncr = 0;
    uint8_t mVolPan = 0;
    uint8_t mVolCtrl = 0;
    uint8_t mVolMode = 0;
    bool mStateOn = false;
};

struct Ics2115DebugState
{
    uint8_t mActiveOsc = 0;
    uint8_t mOscSelect = 0;
    uint8_t mRegSelect = 0;
    uint8_t mVmode = 0;
    uint8_t mIrqPending = 0;
    uint8_t mIrqEnabled = 0;
    bool mIrqOn = false;
    uint8_t mOscIrqPendingCount = 0;
    uint8_t mVolIrqPendingCount = 0;
    uint8_t mStateOnCount = 0;
    uint8_t mStopCount = 0;
    uint8_t mSeqState = 0;
    uint8_t mSeqVoiceIdx = 0;
    bool mSampleTick = false;
    uint8_t mHostDout = 0;
    bool mHostCsN = true;
    bool mHostRdN = true;
    bool mHostWrN = true;
    bool mHostIrq = false;
    bool mHostReady = true;
    bool mResetN = true;
    bool mRomDataValid = false;
    uint32_t mRomAddr = 0;
    uint16_t mRomData = 0;
    int16_t mAudioLeft = 0;
    int16_t mAudioRight = 0;
    bool mAudioValid = false;
    std::vector<Ics2115TimerState> mTimers;
    std::vector<Ics2115VoiceState> mVoices;
};

struct StateListResult
{
    std::vector<std::string> mStates;
};

struct Condition
{
    enum class Type
    {
        SIGNAL_EQUALS,
        SIGNAL_NOT_EQUALS,
        SIGNAL_LESS_THAN,
        SIGNAL_LESS_EQUAL,
        SIGNAL_GREATER_THAN,
        SIGNAL_GREATER_EQUAL,
        CPU_PC_EQUALS,
        CPU_PC_IN_RANGE,
        CPU_PC_OUT_OF_RANGE,
        AND,
        OR,
        NOT
    };

    Type mType = Type::SIGNAL_EQUALS;
    std::string mSignal;
    uint64_t mValue = 0;
    uint64_t mValue2 = 0;
    std::vector<Condition> mChildren;
};

struct RunUntilRequest
{
    Condition mCondition;
    uint64_t mTimeoutCycles = 0;
};

class SimController
{
  public:
    ControllerResult<EmptyResult> Initialize(bool headless);
    ControllerResult<EmptyResult> Shutdown();

    ControllerResult<EmptyResult> LoadGame(const std::string &name);
    ControllerResult<EmptyResult> LoadMra(const std::string &path);
    ControllerResult<EmptyResult> Reset(uint64_t cycles);

    ControllerResult<RunResult> RunCycles(uint64_t cycles);
    ControllerResult<RunResult> RunFrames(uint64_t frames);
    ControllerResult<RunResult> RunUntil(const RunUntilRequest &request);

    ControllerResult<SimStatus> GetStatus() const;
    ControllerResult<CpuState> GetCpuState() const;

    ControllerResult<MemoryReadResult> ReadMemory(const std::string &region, uint32_t address, uint32_t size) const;
    ControllerResult<EmptyResult> WriteMemory(const std::string &region, uint32_t address, const std::vector<uint8_t> &data);
    ControllerResult<std::vector<std::string>> ListRegions() const;
    ControllerResult<EmptyResult> DebugLinkStart(uint32_t commsWordAddr = 0x1F800);
    ControllerResult<EmptyResult> DebugLinkStop();
    ControllerResult<EmptyResult> DebugLinkWrite(const std::vector<uint8_t> &data, uint64_t timeoutCyclesPerByte = 2000000);
    ControllerResult<DebugLinkReadResult> DebugLinkRead(uint32_t maxBytes, uint32_t minBytes = 0, uint64_t timeoutCycles = 2000000);
    ControllerResult<SignalReadResult> ReadSignal(const std::string &signal) const;
    ControllerResult<SignalListResult> ListSignals() const;

    ControllerResult<EmptyResult> SetDipSwitch(uint8_t switchIndex, bool enabled);
    ControllerResult<EmptyResult> SetDipSwitches(uint8_t value);
    uint8_t GetDipSwitches() const;
    ControllerResult<EmptyResult> SetRegion(uint8_t value);
    uint8_t GetRegion() const;
    ControllerResult<InputStateResult> GetInputState() const;
    ControllerResult<EmptyResult> SetInput(const std::string &name, bool pressed);
    ControllerResult<EmptyResult> ClearInput(const std::string &name);
    ControllerResult<RunResult> PressInput(const std::string &name);

    ControllerResult<StateListResult> ListStates() const;
    ControllerResult<EmptyResult> SaveState(const std::string &filename);
    ControllerResult<EmptyResult> LoadState(const std::string &filename);

    ControllerResult<EmptyResult> SaveNvram(const std::string &filename);
    ControllerResult<EmptyResult> LoadNvram(const std::string &filename);

    ControllerResult<EmptyResult> StartTrace(const std::string &filename, int depth);
    ControllerResult<EmptyResult> StopTrace();
    ControllerResult<EmptyResult> StartAudioCapture(const std::string &filename);
    ControllerResult<EmptyResult> StopAudioCapture();
    ControllerResult<ScreenshotResult> SaveScreenshot(const std::string &path);
    ControllerResult<FlipResult> SetFlip(bool flipX, bool flipY);
    ControllerResult<GuiStateResult> GetGuiState() const;
    ControllerResult<Ics2115DebugState> GetIcs2115DebugState() const;
    ControllerResult<EmptyResult> SetIcs2115VoiceState(uint32_t index, const Ics2115VoiceState &voice);
    ControllerResult<EmptyResult> SetIcs2115GlobalRegister(const std::string &name, uint32_t value);
    ControllerResult<GuiOverrideResult> SetGuiOverrideByIndex(uint32_t index, uint16_t value, bool pulse = false);
    ControllerResult<GuiOverrideResult> SetGuiOverrideByLabel(const std::string &label, uint16_t value, bool pulse = false);

  private:
    bool mInitialized = false;
    bool mHeadless = false;
    SimState *mStateManager = nullptr;
    uint8_t mDipSwitch = 0;
    uint8_t mRegion = 0xff;
    mutable std::unordered_map<std::string, vpiHandle> mVpiHandleCache;

    bool EvaluateCondition(const Condition &condition) const;
    ControllerResult<MemoryRegion> ParseRegion(const std::string &name) const;
    ControllerResult<SignalReadResult> ReadSignalValue(const std::string &signal) const;
    ControllerResult<SignalReadResult> ReadSignalValueBuiltin(const std::string &signal) const;
    ControllerResult<SignalReadResult> ReadSignalValueVpi(const std::string &signal) const;
    vpiHandle LookupVpiHandle(const std::string &signal) const;
    ControllerResult<SignalListResult> ListSignalsVpi() const;
    ControllerResult<uint32_t> ParseInputBits(const std::string &name) const;
    void ApplyInputState() const;
    RunStopReason ConvertTickStopReason(TickStopReason reason) const;
    ControllerResult<EmptyResult> EnsureInitialized() const;
};

extern SimController gSimController;
