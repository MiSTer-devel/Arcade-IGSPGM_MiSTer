#include "sim_state.h"
#include "PGM.h"
#include "sim_ddr.h"
#include "sim_core.h"
#include "PGM___024root.h"

#include <dirent.h>
#include <algorithm>
#include <cstring>
#include <sys/stat.h>
#include <sys/types.h>
#include <sstream>
#include <iomanip>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <functional>

namespace
{
uint64_t GetEnvU64(const char *name, uint64_t defaultValue)
{
    const char *value = std::getenv(name);
    if (!value || !*value)
        return defaultValue;

    char *end = nullptr;
    uint64_t parsed = std::strtoull(value, &end, 0);
    return end != value ? parsed : defaultValue;
}

const char *SaveStateStateName(uint8_t state)
{
    switch (state)
    {
    case 0: return "IDLE";
    case 1: return "SAVE_WAIT_PAUSE";
    case 2: return "SAVE_WAIT_IRQ";
    case 3: return "SAVE_WAIT_WRITE";
    case 4: return "SAVE_WAIT_IRQ_EXIT";
    case 5: return "SAVE_WAIT_SSP_SAVE";
    case 6: return "RESTORE_WAIT_PAUSE";
    case 7: return "RESTORE_WAIT_READ";
    case 8: return "RESTORE_HOLD_RESET";
    case 9: return "RESTORE_WAIT_RESET";
    default: return "UNKNOWN";
    }
}

const char *MemoryStreamStateName(uint32_t state)
{
    switch (state)
    {
    case 0: return "IDLE";
    case 1: return "READ_MEM_REQ";
    case 2: return "READ_MEM_WAIT";
    case 3: return "READ_STREAM";
    case 4: return "WRITE_GATHER";
    case 5: return "WRITE_MEM_REQ";
    case 6: return "WRITE_MEM_FINAL_REQ";
    case 7: return "WRITE_MEM_FINAL_WAIT";
    case 8: return "WRITE_MEM_WAIT";
    case 9: return "QUERY_GATHER_FIRST";
    case 10: return "QUERY_GATHER_NEXT";
    case 11: return "QUERY_GATHER_WAIT";
    case 12: return "QUERY_SCATTER_WAIT";
    case 13: return "READ_HEADER";
    case 14: return "READ_HEADER_WAIT";
    case 15: return "WRITE_HEADER";
    case 16: return "WRITE_HEADER_WAIT";
    default: return "UNKNOWN";
    }
}

void PrintStateProgress(const char *op, const char *phase, PGM *top, uint64_t elapsedTicks, const char *prefix = "progress")
{
    auto *root = top->rootp;
    const uint8_t ssState = top->ss_state_out;
    const uint32_t streamState = root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__state;

    std::fprintf(stderr,
                 "[sim-state] %s %s: %s elapsed=%" PRIu64
                 " ss=%s(%u) pause=%u paused=%u read=%u write=%u reset_cnt=%u"
                 " ssp_save=0x%08x ssp_restore=0x%08x ics_ready=%u ics_busy=%u"
                 " stream=%s(%u) is_reading=%u rd_req=%u wr_req=%u query=%u"
                 " chunk_idx=%u chunk_sel=%u chunk_addr=0x%08x remaining=%u width=%u word=%u"
                 " current=0x%08x end=0x%08x ddr_busy=%u ddr_read_done=%u\n",
                 op,
                 phase,
                 prefix,
                 elapsedTicks,
                 SaveStateStateName(ssState),
                 ssState,
                 root->sim_top__DOT__pgm_inst__DOT__ss_pause,
                 root->sim_top__DOT__pgm_inst__DOT__ss_paused,
                 root->sim_top__DOT__pgm_inst__DOT__ss_read,
                 root->sim_top__DOT__pgm_inst__DOT__ss_write,
                 root->sim_top__DOT__pgm_inst__DOT__ss_reset_counter,
                 root->sim_top__DOT__pgm_inst__DOT__ss_saved_ssp,
                 root->sim_top__DOT__pgm_inst__DOT__ss_restore_ssp,
                 root->sim_top__DOT__pgm_inst__DOT__ics2115_ss_ready,
                 root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__ss_busy_local,
                 MemoryStreamStateName(streamState),
                 streamState,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__is_reading,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT____Vcellout__memory_stream__read_req,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT____Vcellout__memory_stream__write_req,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT____Vcellout__memory_stream__query_req,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_index,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_select,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT____Vcellout__memory_stream__chunk_address,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_remaining,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_width,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__word_counter,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__current_addr,
                 root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__end_addr,
                 top->ddr_busy,
                 top->ddr_read_complete);
    std::fflush(stderr);
}

bool TickUntilStateCondition(PGM *top, const char *op, const char *phase, const std::function<bool()> &condition)
{
    const uint64_t timeoutTicks = GetEnvU64("PGM_STATE_TIMEOUT_TICKS", 20'000'000ull);
    const uint64_t progressTicks = GetEnvU64("PGM_STATE_PROGRESS_TICKS", 500'000ull);
    const uint64_t startTicks = gSimCore.GetTotalTicks();
    uint64_t lastProgressTicks = startTicks;
    uint8_t lastSsState = top->ss_state_out;

    PrintStateProgress(op, phase, top, 0, "start");

    // Set PGM_STATE_SECTION_TRACE=1 to log each savestate section as memory_stream
    // writes (save) or parses (restore) it - useful for diagnosing stream desyncs.
    const bool sectionTrace = GetEnvU64("PGM_STATE_SECTION_TRACE", 0) != 0;
    uint32_t prevStreamState = 0xffffffff;

    while (!condition())
    {
        TickResult tickResult = gSimCore.Tick(1);
        const uint64_t nowTicks = gSimCore.GetTotalTicks();
        const uint64_t elapsedTicks = nowTicks - startTicks;
        const uint8_t ssState = top->ss_state_out;
        const bool changed = ssState != lastSsState;

        if (sectionTrace)
        {
            auto *root = top->rootp;
            const uint32_t ms = root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__state;
            // QUERY_SCATTER_WAIT(12): a section header was just parsed during restore.
            if (ms == 12 && prevStreamState != 12)
            {
                std::fprintf(stderr,
                    "[section] idx=%u width=%u remaining=%u current=0x%08x ssp_restore=0x%08x\n",
                    root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_index,
                    root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_width,
                    root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__chunk_remaining,
                    root->sim_top__DOT__pgm_inst__DOT__save_state_data__DOT__memory_stream__DOT__current_addr,
                    root->sim_top__DOT__pgm_inst__DOT__ss_restore_ssp);
            }
            prevStreamState = ms;
        }

        if (tickResult.mReason != TickStopReason::COMPLETED)
        {
            PrintStateProgress(op, phase, top, elapsedTicks, "stopped");
            return false;
        }

        if (changed || (nowTicks - lastProgressTicks) >= progressTicks)
        {
            PrintStateProgress(op, phase, top, elapsedTicks);
            lastProgressTicks = nowTicks;
            lastSsState = ssState;
        }

        if (elapsedTicks >= timeoutTicks)
        {
            PrintStateProgress(op, phase, top, elapsedTicks, "timeout");
            return false;
        }
    }

    PrintStateProgress(op, phase, top, gSimCore.GetTotalTicks() - startTicks, "done");
    return true;
}
} // namespace

SimState::SimState(PGM *top, SimDDR *memory, int offset, int size)
    : mTop(top), mMemory(memory), mOffset(offset), mSize(size), mGameName("unknown")
{
}

void SimState::SetGameName(const char *gameName)
{
    mGameName = gameName;
    EnsureStateDirectory();
}

void SimState::EnsureStateDirectory()
{
    // Create states directory if it doesn't exist
    mkdir("states", 0755);

    // Create game-specific directory
    std::string gameDir = "states/" + mGameName;
    mkdir(gameDir.c_str(), 0755);
}

std::string SimState::GetStatePath(const char *filename)
{
    return "states/" + mGameName + "/" + filename;
}

bool SimState::SaveState(const char *filename)
{
    std::string fullPath = GetStatePath(filename);
    std::fprintf(stderr, "[sim-state] save begin: %s\n", fullPath.c_str());
    std::fflush(stderr);

    mTop->ss_index = 0;
    mTop->ss_do_save = 1;
    if (!TickUntilStateCondition(mTop, "save", "request accepted", [&] { return mTop->ss_state_out != 0; }))
    {
        mTop->ss_do_save = 0;
        return false;
    }

    mTop->ss_do_save = 0;
    if (!TickUntilStateCondition(mTop, "save", "state machine idle", [&] { return mTop->ss_state_out == 0; }))
        return false;

    if (!mMemory->SaveData(fullPath.c_str(), mOffset, mSize))
        return false;

    std::fprintf(stderr, "[sim-state] save complete: %s\n", fullPath.c_str());
    std::fflush(stderr);
    return true;
}

bool SimState::RestoreState(const char *filename)
{
    std::string fullPath = GetStatePath(filename);
    std::fprintf(stderr, "[sim-state] restore begin: %s\n", fullPath.c_str());
    std::fflush(stderr);

    struct stat st;
    if (stat(fullPath.c_str(), &st) == 0)
    {
        std::fprintf(stderr, "[sim-state] restore file size: %lld bytes\n", static_cast<long long>(st.st_size));
        std::fflush(stderr);
    }

    if (!mMemory->LoadData(fullPath.c_str(), mOffset, 1)) // Pass stride=1 explicitly
        return false;

    mTop->ss_index = 0;
    mTop->ss_do_restore = 1;
    if (!TickUntilStateCondition(mTop, "restore", "request accepted", [&] { return mTop->ss_state_out != 0; }))
    {
        mTop->ss_do_restore = 0;
        return false;
    }

    mTop->ss_do_restore = 0;
    if (!TickUntilStateCondition(mTop, "restore", "state machine idle", [&] { return mTop->ss_state_out == 0; }))
        return false;

    {
        auto *root = mTop->rootp;
        uint64_t fileVer = root->sim_top__DOT__pgm_inst__DOT__ss_restored_version;
        // SV string literals are packed big-endian (first char in the high byte);
        // decode MSB-first and skip leading nulls from the zero-extension.
        char ascii[9] = {0};
        int n = 0;
        for (int i = 7; i >= 0; i--)
        {
            char c = static_cast<char>((fileVer >> (8 * i)) & 0xff);
            if (c == 0 && n == 0)
                continue;
            ascii[n++] = c;
        }
        std::fprintf(stderr, "[sim-state] restored build version=\"%s\"\n",
                     ascii);
    }

    std::fprintf(stderr, "[sim-state] restore complete: %s\n", fullPath.c_str());
    std::fflush(stderr);
    return true;
}

std::vector<std::string> SimState::GetPgmstateFiles()
{
    std::vector<std::string> files;
    DIR *dir;
    struct dirent *ent;

    std::string gameDir = "states/" + mGameName;

    if ((dir = opendir(gameDir.c_str())) != NULL)
    {
        while ((ent = readdir(dir)) != NULL)
        {
            std::string filename = ent->d_name;
            // Check if filename ends with .pgmstate
            if (filename.size() > 9 && filename.substr(filename.size() - 9) == ".pgmstate")
            {
                files.push_back(filename);
            }
        }
        closedir(dir);
    }

    // Sort file names
    std::sort(files.begin(), files.end());

    return files;
}

std::string SimState::GenerateNextStateName()
{
    std::vector<std::string> existingFiles = GetPgmstateFiles();

    // Find the next available number
    int nextNum = 0;
    bool found = false;

    while (!found && nextNum < 1000)
    {
        // Generate filename with 3-digit zero-padded number
        std::stringstream ss;
        ss << std::setfill('0') << std::setw(3) << nextNum << ".pgmstate";
        std::string candidate = ss.str();

        // Check if this filename already exists
        bool exists = false;
        for (const auto &file : existingFiles)
        {
            if (file.find(candidate.substr(0, 3)) == 0)
            {
                exists = true;
                break;
            }
        }

        if (!exists)
        {
            found = true;
            return candidate;
        }

        nextNum++;
    }

    // Fallback if somehow we have 1000 save states
    return "999.pgmstate";
}
