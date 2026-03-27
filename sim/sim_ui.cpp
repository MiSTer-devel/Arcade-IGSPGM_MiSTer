#include "imgui_wrap.h"
#include "sim_ui.h"
#include "imgui_wrap.h"
#include "third_party/imgui_memory_editor.h"
#include "sim_core.h"
#include "sim_state.h"
#include "sim_hierarchy.h"
#include "sim_command.h"
#include "games.h"
#include "PGM.h"
#include "PGM___024root.h"
#include "verilated_fst_c.h"
#include "sim_sdram.h"
#include "sim_ddr.h"

extern SimState *state_manager;

static CommandQueue *g_command_queue = nullptr;

extern uint32_t dipswitch_a;
extern uint32_t dipswitch_b;

class MemoryInterfaceEditor : public MemoryEditor
{
  public:
    MemoryInterfaceEditor(MemoryInterface &mem) : MemoryEditor(), mMemory(mem)
    {
        ReadFn = ReadMem;
        WriteFn = WriteMem;
        UserData = this;
    }

    void DrawContents()
    {
        MemoryEditor::DrawContents(nullptr, mMemory.GetSize());
    }

    static ImU8 ReadMem(const ImU8 *, size_t off, void *user)
    {
        MemoryInterfaceEditor *_this = (MemoryInterfaceEditor *)user;
        ImU8 data;
        _this->mMemory.Read(off, 1, &data);
        return data;
    }

    static void WriteMem(ImU8 *, size_t off, ImU8 data, void *user)
    {
        MemoryInterfaceEditor *_this = (MemoryInterfaceEditor *)user;
        _this->mMemory.Write(off, 1, &data);
    }

    MemoryInterface &mMemory;
};

void ui_init(const char *title)
{
    imgui_init(title);
}

void ui_set_command_queue(CommandQueue *queue)
{
    g_command_queue = queue;
}

bool ui_begin_frame()
{
    return imgui_begin_frame();
}

void ui_end_frame()
{
    imgui_end_frame();
}

static bool refresh_state_files = true;

void ui_game_changed()
{
    char title[64];
    const char *name = gSimCore.GetGameName();

    snprintf(title, sizeof(title), "IGS PGM - %s", name);
    imgui_set_title(title);
    refresh_state_files = true;
}

void ui_draw()
{
    if (ImGui::Begin("Simulation Control"))
    {
        ImGui::LabelText("Ticks", "%llu", gSimCore.mTotalTicks);
        ImGui::Checkbox("Run", &gSimCore.mSimulationRun);
        if (ImGui::Button("Step"))
        {
            gSimCore.mSimulationStep = true;
            gSimCore.mSimulationRun = false;
        }
        ImGui::InputInt("Step Size", &gSimCore.mSimulationStepSize);
        ImGui::Checkbox("Step Frame", &gSimCore.mSimulationStepVblank);

        ImGui::Checkbox("WP Set", &gSimCore.mSimulationWpSet);
        ImGui::SameLine();
        ImGui::InputInt("##wpaddr", &gSimCore.mSimulationWpAddr, 0, 0, ImGuiInputTextFlags_CharsHexadecimal);

        if (ImGui::Button("Reset"))
        {
            g_command_queue->add(Command(CommandType::RESET, 100));
        }

        ImGui::SameLine();
        ImGui::Checkbox("Pause", &gSimCore.mSystemPause);

        ImGui::Separator();

        // Save/Restore State Section
        ImGui::Text("Save/Restore State");

        static char state_filename[256] = "state.f2state";
        ImGui::InputText("State Filename", state_filename, sizeof(state_filename));

        static std::vector<std::string> state_files;
        static int selected_state_file = -1;

        // Auto-generate filename when file list is loaded/updated
        if (refresh_state_files)
        {
            state_files = state_manager->get_f2state_files();
            std::string auto_name = state_manager->generate_next_state_name();
            strncpy(state_filename, auto_name.c_str(), sizeof(state_filename) - 1);
            state_filename[sizeof(state_filename) - 1] = '\0';
            refresh_state_files = false;
        }

        if (ImGui::Button("Save State"))
        {
            // Ensure filename has .f2state extension
            std::string filename = state_filename;
            if (filename.size() < 8 || filename.substr(filename.size() - 8) != ".f2state")
            {
                filename += ".f2state";
                strncpy(state_filename, filename.c_str(), sizeof(state_filename) - 1);
                state_filename[sizeof(state_filename) - 1] = '\0';
            }

            if (state_manager->save_state(state_filename))
            {
                // Update file list after successfully saving
                state_files = state_manager->get_f2state_files();
                // Try to select the newly saved file
                for (size_t i = 0; i < state_files.size(); i++)
                {
                    if (state_files[i] == state_filename)
                    {
                        selected_state_file = i;
                        break;
                    }
                }
                // Auto-generate next filename after successful save
                std::string auto_name = state_manager->generate_next_state_name();
                strncpy(state_filename, auto_name.c_str(), sizeof(state_filename) - 1);
                state_filename[sizeof(state_filename) - 1] = '\0';
            }
        }

        // Show list of state files
        if (state_files.size() > 0)
        {
            ImGui::Text("Available State Files:");
            ImGui::BeginChild("StateFiles", ImVec2(0, 100), true);
            for (size_t i = 0; i < state_files.size(); i++)
            {
                if (ImGui::Selectable(state_files[i].c_str(), selected_state_file == (int)i, ImGuiSelectableFlags_AllowDoubleClick))
                {
                    selected_state_file = (int)i;
                    if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left))
                    {
                        state_manager->restore_state(state_files[i].c_str());
                    }
                }
            }
            ImGui::EndChild();
        }
        else
        {
            ImGui::Text("No state files found (*.f2state)");
        }

        ImGui::Separator();

        ImGui::PushItemWidth(100);
        if (ImGui::InputInt("Trace Depth", &gSimCore.mTraceDepth, 1, 10,
                            gSimCore.mTraceActive ? ImGuiInputTextFlags_ReadOnly : ImGuiInputTextFlags_None))
        {
            gSimCore.mTraceDepth = std::min(std::max(gSimCore.mTraceDepth, 1), 99);
        }
        ImGui::PopItemWidth();
        ImGui::InputText("Filename", gSimCore.mTraceFilename, sizeof(gSimCore.mTraceFilename),
                         gSimCore.IsTraceActive() ? ImGuiInputTextFlags_ReadOnly : ImGuiInputTextFlags_None);
        if (ImGui::Button(gSimCore.IsTraceActive() ? "Stop Tracing###TraceBtn" : "Start Tracing###TraceBtn"))
        {
            if (gSimCore.IsTraceActive())
            {
                gSimCore.StopTrace();
            }
            else
            {
                if (strlen(gSimCore.mTraceFilename) > 0)
                {
                    gSimCore.StartTrace(gSimCore.mTraceFilename, gSimCore.mTraceDepth);
                }
            }
        }
    }

    ImGui::End();
}

class DipswitchWindow : public Window
{
  public:
    DipswitchWindow() : Window("Dipswitches")
    {
    }

    void Init() {};
    void Draw()
    {
        if (ImGui::BeginTable("dipswitches", 9))
        {
            ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthStretch);
            for (int i = 0; i < 8; i++)
            {
                char n[2];
                n[0] = '0' + i;
                n[1] = 0;
                ImGui::TableSetupColumn(n, ImGuiTableColumnFlags_WidthFixed);
            }
            ImGui::TableHeadersRow();
            ImGui::TableNextRow();
            ImGui::TableNextColumn();
            ImGui::Text("DWSA");
            for (int i = 0; i < 8; i++)
            {
                ImGui::TableNextColumn();
                ImGui::PushID(i);
                ImGui::CheckboxFlags("##dwsa", &dipswitch_a, ((uint32_t)1 << i));
                ImGui::PopID();
            }
            ImGui::TableNextColumn();
            ImGui::Text("DWSB");
            for (int i = 0; i < 8; i++)
            {
                ImGui::TableNextColumn();
                ImGui::PushID(i);
                ImGui::CheckboxFlags("##dwsb", &dipswitch_b, ((uint32_t)1 << i));
                ImGui::PopID();
            }
            ImGui::EndTable();
        }
    }
};

DipswitchWindow s_DipswitchWindow;

class ROMWindow : public Window
{
  public:
    struct Tab
    {
        const char *mName;
        std::unique_ptr<MemoryInterfaceEditor> mEditor;

        Tab(const char *name, MemoryInterface &memory) : mName(name), mEditor(std::make_unique<MemoryInterfaceEditor>(memory))
        {
        }
    };

    std::vector<Tab> mTabs;

    ROMWindow() : Window("ROM View")
    {
    }

    void Init()
    {
        mTabs.clear();
        mTabs.emplace_back("BIOS", gSimCore.Memory(MemoryRegion::BIOS_ROM));
        mTabs.emplace_back("T", gSimCore.Memory(MemoryRegion::TILE_ROM));
        mTabs.emplace_back("Program", gSimCore.Memory(MemoryRegion::PROGRAM_ROM));
    }

    void Draw()
    {
        if (ImGui::BeginTabBar("rom_tabs"))
        {
            for (auto &it : mTabs)
            {
                if (ImGui::BeginTabItem(it.mName))
                {
                    it.mEditor->DrawContents();
                    ImGui::EndTabItem();
                }
            }
            ImGui::EndTabBar();
        }
    }
};

ROMWindow s_ROMWindow;

class RAMWindow : public Window
{
  public:
    struct Tab
    {
        const char *mName;
        std::unique_ptr<MemoryInterfaceEditor> mEditor;

        Tab(const char *name, MemoryInterface &memory) : mName(name), mEditor(std::make_unique<MemoryInterfaceEditor>(memory))
        {
        }
    };

    std::vector<Tab> mTabs;

    RAMWindow() : Window("RAM View")
    {
    }

    void Init()
    {
        mTabs.clear();
        mTabs.emplace_back("Work", gSimCore.Memory(MemoryRegion::WORK_RAM));
        mTabs.emplace_back("Video", gSimCore.Memory(MemoryRegion::VIDEO_RAM));
        mTabs.emplace_back("Audio", gSimCore.Memory(MemoryRegion::AUDIO_RAM));
        mTabs.emplace_back("Palette", gSimCore.Memory(MemoryRegion::PALETTE_RAM));
    }

    void Draw()
    {
        if (ImGui::BeginTabBar("memory_tabs"))
        {
            for (auto &it : mTabs)
            {
                if (ImGui::BeginTabItem(it.mName))
                {
                    it.mEditor->DrawContents();
                    ImGui::EndTabItem();
                }
            }
            ImGui::EndTabBar();
        }
    }
};

RAMWindow s_RAMWindow;
