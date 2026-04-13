#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "m68k.h"
#include "sim_core.h"

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

struct ScreenshotResult
{
    std::string mPath;
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
    ControllerResult<std::vector<std::string>> ListRegions() const;

    ControllerResult<EmptyResult> SetDipSwitchA(uint8_t value);
    ControllerResult<EmptyResult> SetDipSwitchB(uint8_t value);

    ControllerResult<StateListResult> ListStates() const;
    ControllerResult<EmptyResult> SaveState(const std::string &filename);
    ControllerResult<EmptyResult> LoadState(const std::string &filename);

    ControllerResult<EmptyResult> StartTrace(const std::string &filename, int depth);
    ControllerResult<EmptyResult> StopTrace();
    ControllerResult<ScreenshotResult> SaveScreenshot(const std::string &path);

  private:
    bool mInitialized = false;
    bool mHeadless = false;
    SimState *mStateManager = nullptr;
    uint8_t mDipSwitchA = 1;
    uint8_t mDipSwitchB = 0;

    bool EvaluateCondition(const Condition &condition) const;
    ControllerResult<MemoryRegion> ParseRegion(const std::string &name) const;
    uint64_t ReadSignalValue(const std::string &signal) const;
    RunStopReason ConvertTickStopReason(TickStopReason reason) const;
    ControllerResult<EmptyResult> EnsureInitialized() const;
};
