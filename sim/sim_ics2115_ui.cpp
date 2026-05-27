#include "sim_ics2115_ui.h"

#include "imgui_wrap.h"
#include "sim_controller.h"
#include "sim_core.h"
#include "PGM.h"
#include "PGM___024root.h"

#include <SDL.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace
{
constexpr int kVoiceCount = 32;
constexpr int kVoiceHistorySamples = 64;
constexpr int kTotalHistorySamples = 100000;
constexpr int kTotalDisplaySamples = 1024;
constexpr int kPlaybackSampleRate = 33068;

template <int SampleCount>
struct RingHistory
{
    std::array<float, SampleCount> mValues{};
    int mHead = 0;
    int mCount = 0;

    void Clear()
    {
        mValues.fill(0.0f);
        mHead = 0;
        mCount = 0;
    }

    void Push(float value)
    {
        mValues[mHead] = value;
        mHead = (mHead + 1) % SampleCount;
        if (mCount < SampleCount)
            mCount++;
    }

    void Ordered(float *dst) const
    {
        const int missing = SampleCount - mCount;
        for (int i = 0; i < missing; i++)
            dst[i] = 0.0f;

        const int start = (mHead - mCount + SampleCount) % SampleCount;
        for (int i = 0; i < mCount; i++)
            dst[missing + i] = mValues[(start + i) % SampleCount];
    }

    void OrderedRecent(float *dst, int count) const
    {
        const int copied = std::min(mCount, count);
        const int missing = count - copied;
        for (int i = 0; i < missing; i++)
            dst[i] = 0.0f;

        const int start = (mHead - copied + SampleCount) % SampleCount;
        for (int i = 0; i < copied; i++)
            dst[missing + i] = mValues[(start + i) % SampleCount];
    }

    std::vector<float> OrderedVector() const
    {
        std::vector<float> result;
        result.resize(mCount);
        const int start = (mHead - mCount + SampleCount) % SampleCount;
        for (int i = 0; i < mCount; i++)
            result[i] = mValues[(start + i) % SampleCount];
        return result;
    }
};

using VoiceHistory = RingHistory<kVoiceHistorySamples>;
using TotalHistory = RingHistory<kTotalHistorySamples>;

struct Ics2115GraphHistory
{
    std::array<VoiceHistory, kVoiceCount> mVoiceWave;
    std::array<VoiceHistory, kVoiceCount> mVoiceVolume;
    TotalHistory mTotalWave;

    void Clear()
    {
        for (auto &history : mVoiceWave)
            history.Clear();
        for (auto &history : mVoiceVolume)
            history.Clear();
        mTotalWave.Clear();
    }
};

Ics2115GraphHistory gHistory;
SDL_AudioDeviceID gPlaybackDevice = 0;
std::string gPlaybackStatus;

uint64_t GetWideBits(const VlWide<8> &wide, int lsb, int width)
{
    uint64_t value = 0;
    for (int bit = 0; bit < width; bit++)
    {
        int absoluteBit = lsb + bit;
        uint32_t word = wide[absoluteBit / 32];
        if ((word >> (absoluteBit % 32)) & 1u)
            value |= (uint64_t{1} << bit);
    }
    return value;
}

int32_t SignExtend24(uint32_t value)
{
    value &= 0x00ffffffu;
    if (value & 0x00800000u)
        value |= 0xff000000u;
    return static_cast<int32_t>(value);
}

float ClampFloat(float value, float minValue, float maxValue)
{
    return std::max(minValue, std::min(maxValue, value));
}

float NormalizeAudio24(uint32_t rawLeft, uint32_t rawRight)
{
    const int32_t left = SignExtend24(rawLeft);
    const int32_t right = SignExtend24(rawRight);
    const float mono = static_cast<float>(left + right) * (0.5f / 8388608.0f);
    return ClampFloat(mono, -1.0f, 1.0f);
}

float NormalizeAudio16(int16_t left, int16_t right)
{
    const float mono = static_cast<float>(static_cast<int>(left) + static_cast<int>(right)) * (0.5f / 32768.0f);
    return ClampFloat(mono, -1.0f, 1.0f);
}

const char *SampleFormatName(uint8_t oscConf)
{
    // OscConf bit 0 is u-law, bit 2 is 8-bit PCM; otherwise samples are 16-bit PCM.
    // The oscillator decode path checks u-law first if both bits are set.
    if (oscConf & 0x02)
        return "16-bit";
    if (oscConf & 0x01)
        return "u-law";
    return "8-bit";
}

const char *VModeFamilyName(uint8_t volMode)
{
    switch (volMode & 0x03)
    {
        case 0: return "slow";
        case 1: return "float";
        case 2: return "linear";
        case 3: return "float";
        default: return "?";
    }
}

template <int SampleCount>
void PlotHistory(const char *id, const RingHistory<SampleCount> &history, ImVec2 size, float minValue, float maxValue)
{
    float values[SampleCount];
    history.Ordered(values);
    ImGui::PlotLines(id, values, SampleCount, 0, nullptr, minValue, maxValue, size);
}

template <int Count>
void PlotWaveValues(const char *id, const float (&values)[Count], ImVec2 size)
{
    float minValue = values[0];
    float maxValue = values[0];
    for (int i = 1; i < Count; i++)
    {
        minValue = std::min(minValue, values[i]);
        maxValue = std::max(maxValue, values[i]);
    }

    const float padding = (maxValue - minValue) * 0.05f;
    minValue -= padding;
    maxValue += padding;

    ImGui::PlotLines(id, values, Count, 0, nullptr, minValue, maxValue, size);
}

template <int SampleCount>
void PlotWaveHistory(const char *id, const RingHistory<SampleCount> &history, ImVec2 size)
{
    float values[SampleCount];
    history.Ordered(values);
    PlotWaveValues(id, values, size);
}

template <int DisplayCount, int SampleCount>
void PlotRecentWaveHistory(const char *id, const RingHistory<SampleCount> &history, ImVec2 size)
{
    float values[DisplayCount];
    history.OrderedRecent(values, DisplayCount);
    PlotWaveValues(id, values, size);
}

bool EnsurePlaybackDevice()
{
    if (gPlaybackDevice != 0)
        return true;

    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0)
    {
        gPlaybackStatus = std::string("Audio init failed: ") + SDL_GetError();
        return false;
    }

    SDL_AudioSpec want{};
    want.freq = kPlaybackSampleRate;
    want.format = AUDIO_F32SYS;
    want.channels = 1;
    want.samples = 1024;
    want.callback = nullptr;

    SDL_AudioSpec have{};
    gPlaybackDevice = SDL_OpenAudioDevice(nullptr, 0, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
    if (gPlaybackDevice == 0)
    {
        gPlaybackStatus = std::string("Audio open failed: ") + SDL_GetError();
        return false;
    }

    if (have.format != AUDIO_F32SYS || have.channels != 1)
    {
        SDL_CloseAudioDevice(gPlaybackDevice);
        gPlaybackDevice = 0;
        gPlaybackStatus = "Audio open failed: F32 mono playback unavailable";
        return false;
    }

    return true;
}

void PlayTotalWaveBuffer()
{
    auto samples = gHistory.mTotalWave.OrderedVector();
    if (samples.empty())
    {
        gPlaybackStatus = "No samples captured";
        return;
    }

    if (!EnsurePlaybackDevice())
        return;

    SDL_ClearQueuedAudio(gPlaybackDevice);
    if (SDL_QueueAudio(gPlaybackDevice, samples.data(), static_cast<Uint32>(samples.size() * sizeof(float))) != 0)
    {
        gPlaybackStatus = std::string("Audio queue failed: ") + SDL_GetError();
        return;
    }

    SDL_PauseAudioDevice(gPlaybackDevice, 0);
    gPlaybackStatus = "Playing " + std::to_string(samples.size()) + " samples";
}

class Ics2115Window : public Window
{
  public:
    Ics2115Window() : Window("ICS2115 Debug")
    {
    }

    void Init() override
    {
        Ics2115DebugUiReset();
    }

    void Draw() override
    {
        auto result = gSimController.GetIcs2115DebugState();
        if (!result.ok)
        {
            ImGui::TextUnformatted(result.errorMessage.c_str());
            return;
        }

        const auto &state = result.value;
        const Ics2115VoiceState *selectedVoice = nullptr;
        for (const auto &voice : state.mVoices)
        {
            if (voice.mIndex == state.mOscSelect)
            {
                selectedVoice = &voice;
                break;
            }
        }
        const uint8_t selectedVMode = selectedVoice ? selectedVoice->mVolMode : 0;
        ImGui::Text("active=%u selected=%u reg=0x%02x sel_vmode=0x%02x[%u %s] seq=%u/%u",
                    state.mActiveOsc,
                    state.mOscSelect,
                    state.mRegSelect,
                    selectedVMode,
                    selectedVMode & 0x03,
                    VModeFamilyName(selectedVMode),
                    state.mSeqState,
                    state.mSeqVoiceIdx);
        ImGui::Text("irq on=%d pending=0x%02x enabled=0x%02x osc_pend=%u vol_pend=%u on=%u stop=%u",
                    state.mIrqOn ? 1 : 0,
                    state.mIrqPending,
                    state.mIrqEnabled,
                    state.mOscIrqPendingCount,
                    state.mVolIrqPendingCount,
                    state.mStateOnCount,
                    state.mStopCount);
        ImGui::Text("host dout=0x%02x cs=%d rd=%d wr=%d irq=%d ready=%d reset=%d  rom addr=0x%06x data=0x%04x valid=%d",
                    state.mHostDout,
                    state.mHostCsN ? 1 : 0,
                    state.mHostRdN ? 1 : 0,
                    state.mHostWrN ? 1 : 0,
                    state.mHostIrq ? 1 : 0,
                    state.mHostReady ? 1 : 0,
                    state.mResetN ? 1 : 0,
                    state.mRomAddr,
                    state.mRomData,
                    state.mRomDataValid ? 1 : 0);
        ImGui::Text("audio L=%d R=%d valid=%d sample_tick=%d",
                    state.mAudioLeft,
                    state.mAudioRight,
                    state.mAudioValid ? 1 : 0,
                    state.mSampleTick ? 1 : 0);

        if (ImGui::BeginTable("ics_timers", 6, ImGuiTableFlags_RowBg | ImGuiTableFlags_Borders | ImGuiTableFlags_SizingStretchProp))
        {
            ImGui::TableSetupColumn("Timer");
            ImGui::TableSetupColumn("Preset");
            ImGui::TableSetupColumn("Scale");
            ImGui::TableSetupColumn("Count");
            ImGui::TableSetupColumn("Period");
            ImGui::TableSetupColumn("Run");
            ImGui::TableHeadersRow();
            for (size_t i = 0; i < state.mTimers.size(); i++)
            {
                const auto &timer = state.mTimers[i];
                ImGui::TableNextRow();
                ImGui::TableNextColumn(); ImGui::Text("%zu", i);
                ImGui::TableNextColumn(); ImGui::Text("0x%02x", timer.mPreset);
                ImGui::TableNextColumn(); ImGui::Text("0x%02x", timer.mScale);
                ImGui::TableNextColumn(); ImGui::Text("0x%06x", timer.mCount);
                ImGui::TableNextColumn(); ImGui::Text("0x%06x", timer.mPeriod);
                ImGui::TableNextColumn(); ImGui::Text("%d", timer.mRunning ? 1 : 0);
            }
            ImGui::EndTable();
        }

        ImGui::Separator();

        if (ImGui::BeginTable("ics_voices", 20, ImGuiTableFlags_RowBg | ImGuiTableFlags_Borders | ImGuiTableFlags_ScrollY | ImGuiTableFlags_SizingFixedFit,
                              ImVec2(0, 420)))
        {
            ImGui::TableSetupScrollFreeze(0, 1);
            ImGui::TableSetupColumn("#");
            ImGui::TableSetupColumn("On");
            ImGui::TableSetupColumn("Wave", ImGuiTableColumnFlags_WidthFixed, 72.0f);
            ImGui::TableSetupColumn("Vol", ImGuiTableColumnFlags_WidthFixed, 72.0f);
            ImGui::TableSetupColumn("OConf");
            ImGui::TableSetupColumn("Fmt");
            ImGui::TableSetupColumn("VCtrl");
            ImGui::TableSetupColumn("Ctl");
            ImGui::TableSetupColumn("FC");
            ImGui::TableSetupColumn("SAddr");
            ImGui::TableSetupColumn("OAcc");
            ImGui::TableSetupColumn("OStart");
            ImGui::TableSetupColumn("OEnd");
            ImGui::TableSetupColumn("VAcc");
            ImGui::TableSetupColumn("VStart");
            ImGui::TableSetupColumn("VEnd");
            ImGui::TableSetupColumn("VIncr");
            ImGui::TableSetupColumn("Pan");
            ImGui::TableSetupColumn("VMode", ImGuiTableColumnFlags_WidthFixed, 72.0f);
            ImGui::TableSetupColumn("Flags");
            ImGui::TableHeadersRow();

            for (const auto &voice : state.mVoices)
            {
                ImGui::PushID(static_cast<int>(voice.mIndex));
                ImGui::TableNextRow();
                ImGui::TableNextColumn(); ImGui::Text("%u", voice.mIndex);
                ImGui::TableNextColumn(); ImGui::Text("%d", voice.mStateOn ? 1 : 0);
                ImGui::TableNextColumn(); PlotWaveHistory("##wave", gHistory.mVoiceWave[voice.mIndex], ImVec2(64.0f, 22.0f));
                ImGui::TableNextColumn(); PlotHistory("##vol", gHistory.mVoiceVolume[voice.mIndex], ImVec2(64.0f, 22.0f), 0.0f, 1.0f);
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mOscConf);
                ImGui::TableNextColumn(); ImGui::TextUnformatted(SampleFormatName(voice.mOscConf));
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mVolCtrl);
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mOscCtl);
                ImGui::TableNextColumn(); ImGui::Text("%04x", voice.mOscFc);
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mOscSaddr);
                ImGui::TableNextColumn(); ImGui::Text("%08x", voice.mOscAcc);
                ImGui::TableNextColumn(); ImGui::Text("%08x", voice.mOscStart);
                ImGui::TableNextColumn(); ImGui::Text("%08x", voice.mOscEnd);
                ImGui::TableNextColumn(); ImGui::Text("%07x", voice.mVolAcc);
                ImGui::TableNextColumn(); ImGui::Text("%07x", voice.mVolStart);
                ImGui::TableNextColumn(); ImGui::Text("%07x", voice.mVolEnd);
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mVolIncr);
                ImGui::TableNextColumn(); ImGui::Text("%02x", voice.mVolPan);
                ImGui::TableNextColumn(); ImGui::Text("%02x[%u %s]", voice.mVolMode, voice.mVolMode & 0x03, VModeFamilyName(voice.mVolMode));
                ImGui::TableNextColumn();
                ImGui::Text("%s%s%s%s",
                            (voice.mOscConf & 0x80) ? "OI " : "",
                            (voice.mVolCtrl & 0x80) ? "VI " : "",
                            (voice.mOscConf & 0x02) ? "OS " : "",
                            (voice.mVolCtrl & 0x02) ? "VS" : "");
                ImGui::PopID();
            }
            ImGui::EndTable();
        }

        ImGui::Separator();
        ImGui::Text("ICS2115 total waveform output - most recent %d of %d samples", kTotalDisplaySamples, gHistory.mTotalWave.mCount);
        if (ImGui::Button("Play full buffer"))
        {
            PlayTotalWaveBuffer();
        }
        if (!gPlaybackStatus.empty())
        {
            ImGui::SameLine();
            ImGui::TextUnformatted(gPlaybackStatus.c_str());
        }
        PlotRecentWaveHistory<kTotalDisplaySamples>("##ics_total_wave", gHistory.mTotalWave, ImVec2(ImGui::GetContentRegionAvail().x, 150.0f));
    }
};

Ics2115Window gIcs2115Window;

bool IsIcs2115WindowVisible()
{
    if (!gIcs2115Window.mEnabled || ImGui::GetCurrentContext() == nullptr)
        return false;

    ImGuiWindow *window = ImGui::FindWindowByName(gIcs2115Window.mTitle.c_str());
    return window != nullptr && window->WasActive && !window->Collapsed && !window->Hidden;
}
} // namespace

void Ics2115DebugUiReset()
{
    gHistory.Clear();
    gPlaybackStatus.clear();
    if (gPlaybackDevice != 0)
        SDL_ClearQueuedAudio(gPlaybackDevice);
}

void Ics2115DebugUiTick()
{
    if (!IsIcs2115WindowVisible() || !gSimCore.mTop)
        return;

    auto *root = gSimCore.mTop->rootp;

    if (!root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_valid)
        return;

    gHistory.mTotalWave.Push(NormalizeAudio16(static_cast<int16_t>(root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_left),
                                              static_cast<int16_t>(root->sim_top__DOT__pgm_inst__DOT__ics2115_audio_right)));

    for (int voiceIndex = 0; voiceIndex < kVoiceCount; voiceIndex++)
    {
        gHistory.mVoiceWave[voiceIndex].Push(NormalizeAudio24(root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__debug_voice_sample_left[voiceIndex],
                                                              root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__debug_voice_sample_right[voiceIndex]));

        const auto &wide = root->sim_top__DOT__pgm_inst__DOT__ics2115__DOT__voice_ram__DOT__ram[voiceIndex];
        const uint32_t volAcc = static_cast<uint32_t>(GetWideBits(wide, 92, 26));
        gHistory.mVoiceVolume[voiceIndex].Push(static_cast<float>(volAcc) / static_cast<float>((1u << 26) - 1u));
    }
}
