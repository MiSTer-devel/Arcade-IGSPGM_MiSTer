#if !defined(IMGUI_WRAP_H)
#define IMGUI_WRAP_H 1

#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui.h"
#include "imgui_internal.h"

#include <string>
#include <vector>

bool ImguiInit(const char *title);
void ImguiShutdown();
void ImguiInitWindows();
bool ImguiBeginFrame();
void ImguiEndFrame();
void ImguiSetTitle(const char *title);

uint32_t ImguiGetButtons();
void ImguiSetButtons(uint32_t buttons);
void ImguiSetButtonBits(uint32_t bits);
void ImguiClearButtonBits(uint32_t bits);

struct SDL_Renderer;
SDL_Renderer *ImguiGetRenderer();

class Window
{
  public:
    Window(const char *name, ImGuiWindowFlags flags = 0);
    virtual ~Window();

    // Called before first frame and after sim is initialized

    void Update();

    virtual void Init() = 0;
    virtual void Draw() = 0;

    static void SortWindows();
    static void *SettingsHandlerReadOpen(ImGuiContext *, ImGuiSettingsHandler *, const char *name);
    static void SettingsHandlerReadLine(ImGuiContext *, ImGuiSettingsHandler *, void *entry, const char *line);
    static void SettingsHandlerWriteAll(ImGuiContext *, ImGuiSettingsHandler *handler, ImGuiTextBuffer *buf);

    std::string mTitle;
    bool mEnabled;
    ImGuiWindowFlags mFlags;

    Window *mNext;
    static Window *gHead;
    static std::vector<Window *> gWindows;
};

#endif // IMGUI_WRAP_H
