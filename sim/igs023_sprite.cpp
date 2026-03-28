#include <SDL.h>

#include "imgui_wrap.h"
#include "sim_core.h"
#include "sim_hierarchy.h"

#include "gfx_cache.h"

#include "PGM.h"
#include "PGM___024root.h"

struct IGS023Sprite
{
    int16_t  mXPos : 11;
    uint16_t mXZoomTable : 4;
    uint16_t mXZoomMode : 1;

    int16_t  mYPos : 11;
    uint16_t mYZoomTable : 4;
    uint16_t mYZoomMode : 1;
    
    uint16_t mMaskMSB : 7;
    uint16_t mPriority : 1;
    uint16_t mColor : 5;
    uint16_t mXFlip : 1;
    uint16_t mYFlip : 1;
    uint16_t mUnk1 : 1;

    uint16_t mMaskLSB : 16;

    uint16_t mHeight : 9;
    uint16_t mWidth16 : 6;
    uint16_t mUnk2 : 1;
};


void get_obj_inst(uint16_t index, IGS023Sprite *inst)
{
    uint8_t *inst_data = (uint8_t *)inst;

    uint16_t offset = index * 5;

    for (int i = 0; i < 5; i++)
    {
        inst_data[(i * 2) + 0] = G_PGM_SIGNAL(work_ram, ram_l).m_storage[offset + i];
        inst_data[(i * 2) + 1] = G_PGM_SIGNAL(work_ram, ram_h).m_storage[offset + i];
    }
}

static void bullet(int x)
{
    if (x != 0)
        ImGui::Bullet();
}

class SpriteWindow : public Window
{
  public:
    bool m_hide_empty = false;

    SpriteWindow() : Window("Sprite Instances")
    {
    }

    void Init() {};

    void Draw()
    {
        ImGui::Checkbox("Hide Empty", &m_hide_empty);

        if (ImGui::BeginTable("obj", 8,
                              ImGuiTableFlags_HighlightHoveredColumn | ImGuiTableFlags_BordersInnerV | ImGuiTableFlags_ScrollY |
                                  ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_RowBg))
        {
            uint32_t colflags = ImGuiTableColumnFlags_AngledHeader;
            ImGui::TableSetupColumn("", colflags & ~ImGuiTableColumnFlags_AngledHeader);
            ImGui::TableSetupColumn("Address", colflags);
            ImGui::TableSetupColumn("X", colflags);
            ImGui::TableSetupColumn("Y", colflags);
            ImGui::TableSetupColumn("Width", colflags);
            ImGui::TableSetupColumn("Height", colflags);
            ImGui::TableSetupColumn("Flip X", colflags);
            ImGui::TableSetupColumn("Flip Y", colflags);
            ImGui::TableSetupScrollFreeze(0, 1);
            ImGui::TableAngledHeadersRow();

            IGS023Sprite insts[256];

            std::vector<int> valid_insts;
            valid_insts.reserve(256);

            for (int i = 0; i < 256; i++)
            {
                get_obj_inst(i, &insts[i]);
                valid_insts.push_back(i);
            }

            int hovered = ImGui::TableGetHoveredRow();

            ImGuiListClipper clipper;
            clipper.Begin(valid_insts.size());
            int row_count = 1;
            int tooltip_idx = -1;
            while (clipper.Step())
            {
                for (uint16_t i = clipper.DisplayStart; i < clipper.DisplayEnd; i++)
                {
                    int index = valid_insts[i];

                    if (row_count == hovered)
                    {
                        tooltip_idx = index;
                    }
                    row_count++;

                    IGS023Sprite &inst = insts[index];
                    ImGui::TableNextRow();
                    ImGui::TableNextColumn();
                    ImGui::Text("%4u", index);
                    ImGui::TableNextColumn();
                    ImGui::Text("%06X", (inst.mMaskMSB << 16) | (inst.mMaskLSB));
                    ImGui::TableNextColumn();
                    ImGui::Text("%4d", inst.mXPos);
                    ImGui::TableNextColumn();
                    ImGui::Text("%4d", inst.mYPos);
                    ImGui::TableNextColumn();
                    ImGui::Text("%4d", inst.mWidth16 * 16);
                    ImGui::TableNextColumn();
                    ImGui::Text("%4d", inst.mHeight);
                    ImGui::TableNextColumn();
                    bullet(inst.mXFlip);
                    ImGui::TableNextColumn();
                    bullet(inst.mYFlip);
                }
            }
/*
            if (tooltip_idx >= 0)
            {
                uint16_t code = extcode[tooltip_idx];
                if (code != 0)
                {
                    SDL_Texture *tex = gSimCore.mGfxCache->GetTexture(MemoryRegion::OBJ_ROM, GfxCacheFormat::TC0200OBJ, code,
                                                                        latched_color[tooltip_idx]);
                    ImGui::BeginTooltip();
                    ImGui::LabelText("Code", "%04X", code);
                    ImGui::LabelText("Color", "%02X", latched_color[tooltip_idx]);
                    ImGui::Image((ImTextureID)tex, ImVec2(64, 64));
                    ImGui::End();
                }
            }
*/
            ImGui::EndTable();
        }
    }
};

SpriteWindow s_SpriteWindow;

/*
class TC0200OBJ_Preview_Window : public Window
{
  public:
    TC0200OBJ_Preview_Window() : Window("TC0200OBJ Preview")
    {
    }
    int m_color = 0;

    void Init() {};
    void Draw()
    {
        ImGui::SliderInt("Color", &m_color, 0, 0xff, "%02X");
        m_color &= 0xff;

        if (ImGui::BeginTable("obj_list", 17,
                              ImGuiTableFlags_HighlightHoveredColumn | ImGuiTableFlags_BordersInnerV | ImGuiTableFlags_ScrollY |
                                  ImGuiTableFlags_SizingFixedFit))
        {
            ImGuiTableColumnFlags colflags = 0;
            ImGui::TableSetupColumn("", colflags);
            ImGui::TableSetupColumn("0", colflags);
            ImGui::TableSetupColumn("1", colflags);
            ImGui::TableSetupColumn("2", colflags);
            ImGui::TableSetupColumn("3", colflags);
            ImGui::TableSetupColumn("4", colflags);
            ImGui::TableSetupColumn("5", colflags);
            ImGui::TableSetupColumn("6", colflags);
            ImGui::TableSetupColumn("7", colflags);
            ImGui::TableSetupColumn("8", colflags);
            ImGui::TableSetupColumn("9", colflags);
            ImGui::TableSetupColumn("A", colflags);
            ImGui::TableSetupColumn("B", colflags);
            ImGui::TableSetupColumn("C", colflags);
            ImGui::TableSetupColumn("D", colflags);
            ImGui::TableSetupColumn("E", colflags);
            ImGui::TableSetupColumn("F", colflags);
            ImGui::TableSetupScrollFreeze(0, 1);
            ImGui::TableHeadersRow();

            ImGuiListClipper clipper;
            clipper.Begin(0x10000 / 16);
            while (clipper.Step())
            {
                for (uint16_t index = clipper.DisplayStart; index < clipper.DisplayEnd; index++)
                {
                    ImGui::TableNextRow();
                    ImGui::TableNextColumn();
                    ImGui::Text("%03Xx", index);
                    uint16_t base_code = index * 16;
                    for (int i = 0; i < 16; i++)
                    {
                        ImGui::TableNextColumn();
                        SDL_Texture *tex =
                            gSimCore.mGfxCache->GetTexture(MemoryRegion::OBJ_ROM, GfxCacheFormat::TC0200OBJ, base_code + i, m_color);
                        ImGui::Image((ImTextureID)tex, ImVec2(32, 32));
                    }
                }
            }

            ImGui::EndTable();
        }
    }
};

TC0200OBJ_Preview_Window s_TC0200OBJ_Preview_Window;
*/
