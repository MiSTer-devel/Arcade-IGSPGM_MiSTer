#include "imgui_wrap.h"
#include "sim_core.h"
#include "PGM.h"
#include "PGM___024root.h"

#include <algorithm>
#include <cstdint>

namespace
{
constexpr int kSpriteCount = 256;
constexpr float kMinInputWidth = 96.0f;
constexpr float kBromInputWidth = 128.0f;
constexpr float kPositionSliderWidth = 220.0f;
constexpr float kTableRowHeight = 28.0f;
constexpr float kTableMinHeight = 220.0f;
constexpr float kTableMinColumnWidth = 52.0f;
constexpr float kTableBromColumnWidth = 76.0f;

struct SpriteRecord
{
    uint16_t d0 = 0;
    uint16_t d1 = 0;
    uint16_t d2 = 0;
    uint16_t d3 = 0;
    uint16_t d4 = 0;
};

uint16_t ClampU16(int value)
{
    return static_cast<uint16_t>(std::clamp(value, 0, 0xffff));
}

int ClampInt(int value, int minValue, int maxValue)
{
    return std::clamp(value, minValue, maxValue);
}

PGM___024root *Root()
{
    return gSimCore.mTop ? gSimCore.mTop->rootp : nullptr;
}

SpriteRecord ReadSprite(PGM___024root *root, int index)
{
    return {
        static_cast<uint16_t>(root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d0[index]),
        static_cast<uint16_t>(root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d1[index]),
        static_cast<uint16_t>(root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d2[index]),
        static_cast<uint16_t>(root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d3[index]),
        static_cast<uint16_t>(root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d4[index]),
    };
}

void WriteSprite(PGM___024root *root, int index, const SpriteRecord &sprite)
{
    root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d0[index] = sprite.d0;
    root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d1[index] = sprite.d1;
    root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d2[index] = sprite.d2;
    root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d3[index] = sprite.d3;
    root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_d4[index] = sprite.d4;
}

uint32_t BromAddress(const SpriteRecord &sprite)
{
    return (static_cast<uint32_t>(sprite.d2 & 0x007f) << 16) | sprite.d3;
}

bool IsTerminator(const SpriteRecord &sprite)
{
    return (sprite.d4 & 0x7fff) == 0;
}

bool InputHex16(const char *label, uint16_t *value, float width = kMinInputWidth)
{
    int edited = *value;
    ImGui::SetNextItemWidth(width);
    if (ImGui::InputInt(label, &edited, 0, 0, ImGuiInputTextFlags_CharsHexadecimal))
    {
        *value = ClampU16(edited);
        return true;
    }
    return false;
}

bool InputMaskedInt(const char *label, uint16_t *word, int shift, int mask, float width = kMinInputWidth)
{
    int value = (*word >> shift) & mask;
    ImGui::SetNextItemWidth(width);
    if (ImGui::InputInt(label, &value, 1, 16))
    {
        value = ClampInt(value, 0, mask);
        *word = static_cast<uint16_t>((*word & ~(mask << shift)) | (value << shift));
        return true;
    }
    return false;
}

bool SliderMaskedInt(const char *label, uint16_t *word, int shift, int mask, float width = kPositionSliderWidth)
{
    int value = (*word >> shift) & mask;
    ImGui::SetNextItemWidth(width);
    if (ImGui::SliderInt(label, &value, 0, mask))
    {
        value = ClampInt(value, 0, mask);
        *word = static_cast<uint16_t>((*word & ~(mask << shift)) | (value << shift));
        return true;
    }
    return false;
}

bool CheckboxBit(const char *label, uint16_t *word, int bit)
{
    bool value = ((*word >> bit) & 1) != 0;
    if (ImGui::Checkbox(label, &value))
    {
        if (value)
            *word = static_cast<uint16_t>(*word | (uint16_t{1} << bit));
        else
            *word = static_cast<uint16_t>(*word & ~(uint16_t{1} << bit));
        return true;
    }
    return false;
}

bool InputBromAddress(const char *label, SpriteRecord *sprite)
{
    int value = static_cast<int>(BromAddress(*sprite));
    ImGui::SetNextItemWidth(kBromInputWidth);
    if (ImGui::InputInt(label, &value, 0, 0, ImGuiInputTextFlags_CharsHexadecimal))
    {
        value = ClampInt(value, 0, 0x7fffff);
        sprite->d2 = static_cast<uint16_t>((sprite->d2 & 0xff80) | ((value >> 16) & 0x007f));
        sprite->d3 = static_cast<uint16_t>(value & 0xffff);
        return true;
    }
    return false;
}

void SetupAutoColumn(const char *label, float minWidth = kTableMinColumnWidth)
{
    const float width = std::max(minWidth, ImGui::CalcTextSize(label).x + ImGui::GetStyle().CellPadding.x * 2.0f);
    ImGui::TableSetupColumn(label, ImGuiTableColumnFlags_WidthFixed, width);
}

class SpriteDebugWindow : public Window
{
  public:
    SpriteDebugWindow() : Window("Sprite Debug")
    {
    }

    void Init() override
    {
    }

    void Draw() override
    {
        auto *root = Root();
        if (!root)
        {
            ImGui::TextUnformatted("Simulator is not initialized.");
            return;
        }

        bool dmaDisabled = root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__debug_sprite_dma_disable != 0;
        if (ImGui::Checkbox("Disable CPU->sprite DMA updates", &dmaDisabled))
        {
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__debug_sprite_dma_disable = dmaDisabled ? 1 : 0;
        }
        ImGui::SameLine();
        if (ImGui::Button("Freeze now"))
        {
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__debug_sprite_dma_disable = 1;
        }
        ImGui::SameLine();
        if (ImGui::Button("Resume DMA"))
        {
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__debug_sprite_dma_disable = 0;
        }

        ImGui::TextWrapped("Freeze after reaching a problem scene, then edit sprite rows. Freeze disables new sprite DMA and stalls CPU "
                           "VRAM/palette accesses through DTACK so the scene remains stable. Changes are applied to igs023_sprite's live "
                           "instance data and are normally visible on the next sprite frame/prescan.");

        int spriteCount = root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_count;
        ImGui::SetNextItemWidth(kMinInputWidth);
        if (ImGui::InputInt("sprite_count", &spriteCount, 1, 16))
        {
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_count = ClampInt(spriteCount, 0, 255);
        }
        ImGui::SameLine();
        ImGui::Text(
            "state=%u idx=%u line=%u hcnt=%u vcnt=%u dma_en=%u", root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__dma_state,
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_index,
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__draw_line, root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__hcnt,
            root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__vcnt, (root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__ctrl[14] & 1) ? 1 : 0);

        // DDR colour-cache effectiveness for the last completed sprite draw
        // (counted in A-ROM word lookups inside igs023_buffer).
        const uint32_t cacheHits = root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__line_buffer__DOT__ddr_cache_hits_frame;
        const uint32_t cacheMisses = root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__line_buffer__DOT__ddr_cache_misses_frame;
        const uint32_t cacheTotal = cacheHits + cacheMisses;
        const double hitPct = cacheTotal ? (100.0 * cacheHits / static_cast<double>(cacheTotal)) : 0.0;
        ImGui::Text("DDR cache (last frame): hits=%u  misses=%u  hit=%.1f%%", cacheHits, cacheMisses, hitPct);

        ImGui::Checkbox("Show all 256 rows", &mShowAllRows);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(kMinInputWidth);
        ImGui::InputInt("Selected", &mSelectedSprite, 1, 16);
        mSelectedSprite = ClampInt(mSelectedSprite, 0, kSpriteCount - 1);

        DrawSelectedEditor(root);
        ImGui::Separator();
        DrawSpriteTable(root);
    }

  private:
    void DrawSelectedEditor(PGM___024root *root)
    {
        SpriteRecord sprite = ReadSprite(root, mSelectedSprite);
        SpriteRecord edited = sprite;

        ImGui::PushID("selected_sprite_editor");
        ImGui::Text("Sprite %d decoded editor%s", mSelectedSprite, IsTerminator(sprite) ? " (terminator)" : "");

        bool changed = false;
        changed |= SliderMaskedInt("X", &edited.d0, 0, 0x7ff);
        ImGui::SameLine();
        changed |= SliderMaskedInt("Y", &edited.d1, 0, 0x3ff);
        ImGui::SameLine();
        changed |= InputMaskedInt("X scale", &edited.d0, 11, 0x1f);
        ImGui::SameLine();
        changed |= InputMaskedInt("Y scale", &edited.d1, 11, 0x1f);

        changed |= InputBromAddress("BROM addr", &edited);
        ImGui::SameLine();
        changed |= InputMaskedInt("Palette", &edited.d2, 8, 0x1f);
        ImGui::SameLine();
        changed |= InputMaskedInt("Width", &edited.d4, 9, 0x3f);
        ImGui::SameLine();
        changed |= InputMaskedInt("Height", &edited.d4, 0, 0x1ff);

        changed |= CheckboxBit("Priority", &edited.d2, 7);
        ImGui::SameLine();
        changed |= CheckboxBit("X flip", &edited.d2, 13);
        ImGui::SameLine();
        changed |= CheckboxBit("Y flip", &edited.d2, 14);

        changed |= InputHex16("D0 raw", &edited.d0);
        ImGui::SameLine();
        changed |= InputHex16("D1 raw", &edited.d1);
        ImGui::SameLine();
        changed |= InputHex16("D2 raw", &edited.d2);
        ImGui::SameLine();
        changed |= InputHex16("D3 raw", &edited.d3);
        ImGui::SameLine();
        changed |= InputHex16("D4 raw", &edited.d4);

        if (changed)
        {
            WriteSprite(root, mSelectedSprite, edited);
        }
        ImGui::PopID();
    }

    void DrawSpriteTable(PGM___024root *root)
    {
        const int spriteCount = root->sim_top__DOT__pgm_inst__DOT__igs023__DOT__sprite__DOT__sprite_count;
        const int rows = mShowAllRows ? kSpriteCount : std::min(kSpriteCount, spriteCount + 1);

        if (!ImGui::BeginTable("sprite_instances", 12,
                               ImGuiTableFlags_RowBg | ImGuiTableFlags_Borders | ImGuiTableFlags_ScrollX | ImGuiTableFlags_ScrollY |
                                   ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_Resizable,
                               ImVec2(0, std::max(kTableMinHeight, ImGui::GetContentRegionAvail().y))))
        {
            return;
        }

        ImGui::TableSetupScrollFreeze(1, 1);
        SetupAutoColumn("#");
        SetupAutoColumn("X");
        SetupAutoColumn("Y");
        SetupAutoColumn("XS");
        SetupAutoColumn("YS");
        SetupAutoColumn("BROM", kTableBromColumnWidth);
        SetupAutoColumn("Pal");
        SetupAutoColumn("Pri");
        SetupAutoColumn("XF");
        SetupAutoColumn("YF");
        SetupAutoColumn("W");
        SetupAutoColumn("H");
        ImGui::TableHeadersRow();

        for (int i = 0; i < rows; i++)
        {
            SpriteRecord sprite = ReadSprite(root, i);
            const bool selected = i == mSelectedSprite;

            ImGui::PushID(i);
            ImGui::TableNextRow(0, kTableRowHeight);
            ImGui::TableNextColumn();
            if (ImGui::Selectable("##select", selected, ImGuiSelectableFlags_SpanAllColumns | ImGuiSelectableFlags_AllowItemOverlap))
                mSelectedSprite = i;
            ImGui::SameLine();
            ImGui::Text("%03d%s", i, IsTerminator(sprite) ? "*" : "");

            ImGui::TableNextColumn();
            ImGui::Text("%u", sprite.d0 & 0x07ff);
            ImGui::TableNextColumn();
            ImGui::Text("%u", sprite.d1 & 0x03ff);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d0 >> 11) & 0x1f);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d1 >> 11) & 0x1f);
            ImGui::TableNextColumn();
            ImGui::Text("%06x", BromAddress(sprite));
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d2 >> 8) & 0x1f);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d2 >> 7) & 1);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d2 >> 13) & 1);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d2 >> 14) & 1);
            ImGui::TableNextColumn();
            ImGui::Text("%u", (sprite.d4 >> 9) & 0x3f);
            ImGui::TableNextColumn();
            ImGui::Text("%u", sprite.d4 & 0x01ff);
            ImGui::PopID();
        }

        ImGui::EndTable();
    }

    bool mShowAllRows = false;
    int mSelectedSprite = 0;
};

SpriteDebugWindow gSpriteDebugWindow;
} // namespace
