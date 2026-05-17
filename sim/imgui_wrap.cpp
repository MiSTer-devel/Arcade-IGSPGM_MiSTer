#include "imgui_wrap.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_sdlrenderer2.h"

#include <stdio.h>
#include <string.h>
#include <SDL.h>

SDL_Window *gSdlWindow = nullptr;
SDL_Renderer *gSdlRenderer = nullptr;

#define BTN_RIGHT 0x0001
#define BTN_LEFT 0x0002
#define BTN_DOWN 0x0004
#define BTN_UP 0x0008
#define BTN_BTN1 0x0010
#define BTN_BTN2 0x0020
#define BTN_BTN3 0x0040
#define BTN_BTN4 0x0080
#define BTN_START 0x00010000

static uint32_t gButtons;

namespace
{
constexpr const char *kWindowSettingsPath = "pgm_sim_window.ini";
constexpr int kDefaultWindowWidth = 1280;
constexpr int kDefaultWindowHeight = 720;
constexpr int kMinWindowWidth = 320;
constexpr int kMinWindowHeight = 240;

struct AppWindowSettings
{
    int x = SDL_WINDOWPOS_CENTERED;
    int y = SDL_WINDOWPOS_CENTERED;
    int w = kDefaultWindowWidth;
    int h = kDefaultWindowHeight;
    bool hasPosition = false;
    bool maximized = false;
};

AppWindowSettings gAppWindowSettings;

void ParseAppWindowSettingLine(AppWindowSettings &settings, const char *line)
{
    char key[64];
    int value;
    if (sscanf(line, " %63[^=]=%d", key, &value) != 2)
        return;

    if (strcmp(key, "x") == 0)
    {
        settings.x = value;
        settings.hasPosition = true;
    }
    else if (strcmp(key, "y") == 0)
    {
        settings.y = value;
        settings.hasPosition = true;
    }
    else if (strcmp(key, "w") == 0)
    {
        settings.w = value;
    }
    else if (strcmp(key, "h") == 0)
    {
        settings.h = value;
    }
    else if (strcmp(key, "maximized") == 0)
    {
        settings.maximized = value != 0;
    }
}

void ValidateAppWindowSettings(AppWindowSettings &settings)
{
    if (settings.w < kMinWindowWidth)
        settings.w = kDefaultWindowWidth;
    if (settings.h < kMinWindowHeight)
        settings.h = kDefaultWindowHeight;
}

AppWindowSettings LoadAppWindowSettings()
{
    AppWindowSettings settings;
    FILE *file = fopen(kWindowSettingsPath, "r");
    if (!file)
        return settings;

    char line[256];
    bool sawSection = false;
    bool inAppWindowSection = false;
    while (fgets(line, sizeof(line), file))
    {
        if (line[0] == '[')
        {
            sawSection = true;
            inAppWindowSection = strncmp(line, "[AppWindow][Main]", 17) == 0;
            continue;
        }

        // Also accept the previous standalone pgm_sim_window.ini format,
        // which had bare x/y/w/h/maximized lines and no section header.
        if (!sawSection || inAppWindowSection)
        {
            ParseAppWindowSettingLine(settings, line);
        }
    }

    fclose(file);
    ValidateAppWindowSettings(settings);
    return settings;
}

void CaptureAppWindowSettings()
{
    if (!gSdlWindow)
        return;

    const Uint32 flags = SDL_GetWindowFlags(gSdlWindow);
    if (flags & SDL_WINDOW_MINIMIZED)
        return;

    SDL_GetWindowPosition(gSdlWindow, &gAppWindowSettings.x, &gAppWindowSettings.y);
    SDL_GetWindowSize(gSdlWindow, &gAppWindowSettings.w, &gAppWindowSettings.h);
    gAppWindowSettings.hasPosition = true;
    gAppWindowSettings.maximized = (flags & SDL_WINDOW_MAXIMIZED) != 0;
    ValidateAppWindowSettings(gAppWindowSettings);
}

void *AppWindowSettingsHandlerReadOpen(ImGuiContext *, ImGuiSettingsHandler *, const char *name)
{
    return strcmp(name, "Main") == 0 ? &gAppWindowSettings : nullptr;
}

void AppWindowSettingsHandlerReadLine(ImGuiContext *, ImGuiSettingsHandler *, void *entry, const char *line)
{
    AppWindowSettings *settings = (AppWindowSettings *)entry;
    ParseAppWindowSettingLine(*settings, line);
    ValidateAppWindowSettings(*settings);
}

void AppWindowSettingsHandlerWriteAll(ImGuiContext *, ImGuiSettingsHandler *handler, ImGuiTextBuffer *buf)
{
    CaptureAppWindowSettings();

    buf->appendf("[%s][Main]\n", handler->TypeName);
    buf->appendf("x=%d\n", gAppWindowSettings.x);
    buf->appendf("y=%d\n", gAppWindowSettings.y);
    buf->appendf("w=%d\n", gAppWindowSettings.w);
    buf->appendf("h=%d\n", gAppWindowSettings.h);
    buf->appendf("maximized=%d\n\n", gAppWindowSettings.maximized ? 1 : 0);
}

void RegisterAppWindowSettingsHandler()
{
    ImGuiSettingsHandler iniHandler;
    iniHandler.TypeName = "AppWindow";
    iniHandler.TypeHash = ImHashStr("AppWindow");
    iniHandler.ClearAllFn = nullptr;
    iniHandler.ReadOpenFn = AppWindowSettingsHandlerReadOpen;
    iniHandler.ReadLineFn = AppWindowSettingsHandlerReadLine;
    iniHandler.ApplyAllFn = nullptr;
    iniHandler.WriteAllFn = AppWindowSettingsHandlerWriteAll;
    ImGui::AddSettingsHandler(&iniHandler);
}
} // namespace

bool ImguiInit(const char *title)
{
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) != 0)
    {
        printf("Error: %s\n", SDL_GetError());
        return false;
    }

    gAppWindowSettings = LoadAppWindowSettings();

    // Create window with SDL_Renderer graphics context
    SDL_WindowFlags windowFlags = (SDL_WindowFlags)(SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
    SDL_Window *window = SDL_CreateWindow(title,
                                          gAppWindowSettings.hasPosition ? gAppWindowSettings.x : SDL_WINDOWPOS_CENTERED,
                                          gAppWindowSettings.hasPosition ? gAppWindowSettings.y : SDL_WINDOWPOS_CENTERED,
                                          gAppWindowSettings.w,
                                          gAppWindowSettings.h,
                                          windowFlags);
    if (window == nullptr)
    {
        printf("Error: SDL_CreateWindow(): %s\n", SDL_GetError());
        return false;
    }

    if (gAppWindowSettings.maximized)
    {
        SDL_MaximizeWindow(window);
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (renderer == nullptr)
    {
        SDL_Log("Error creating SDL_Renderer!");
        return false;
    }

    // Setup Dear ImGui context
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = kWindowSettingsPath;
    // io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable
    // Keyboard Controls io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad; //
    // Enable Gamepad Controls

    // Setup Dear ImGui style
    ImGui::StyleColorsDark();
    // ImGui::StyleColorsLight();

    // Setup Platform/Renderer backends
    ImGui_ImplSDL2_InitForSDLRenderer(window, renderer);
    ImGui_ImplSDLRenderer2_Init(renderer);

    gSdlWindow = window;
    gSdlRenderer = renderer;

    Window::SortWindows();

    ImGuiSettingsHandler iniHandler;
    iniHandler.TypeName = "SimWindow";
    iniHandler.TypeHash = ImHashStr("SimWindow");
    iniHandler.ClearAllFn = nullptr;
    iniHandler.ReadOpenFn = Window::SettingsHandlerReadOpen;
    iniHandler.ReadLineFn = Window::SettingsHandlerReadLine;
    iniHandler.ApplyAllFn = nullptr;
    iniHandler.WriteAllFn = Window::SettingsHandlerWriteAll;
    ImGui::AddSettingsHandler(&iniHandler);
    RegisterAppWindowSettingsHandler();

    return true;
}

void ImguiShutdown()
{
    if (ImGui::GetCurrentContext())
    {
        ImGuiIO &io = ImGui::GetIO();
        if (io.IniFilename)
        {
            ImGui::SaveIniSettingsToDisk(io.IniFilename);
        }

        ImGui_ImplSDLRenderer2_Shutdown();
        ImGui_ImplSDL2_Shutdown();
        ImGui::DestroyContext();
    }

    if (gSdlRenderer)
    {
        SDL_DestroyRenderer(gSdlRenderer);
        gSdlRenderer = nullptr;
    }
    if (gSdlWindow)
    {
        SDL_DestroyWindow(gSdlWindow);
        gSdlWindow = nullptr;
    }
    SDL_Quit();
}

void ImguiInitWindows()
{
    Window::SortWindows();

    for (Window *window : Window::gWindows)
    {
        window->Init();
    }
}

bool ImguiBeginFrame()
{
    static uint64_t sPrevTicks = 0;

    uint64_t ticks = SDL_GetTicks64();
    uint64_t delta = ticks - sPrevTicks;
    if (delta < 16)
    {
        SDL_Delay((int)(16 - delta));
    }

    sPrevTicks = SDL_GetTicks64();

    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        ImGui_ImplSDL2_ProcessEvent(&event);
        if (event.type == SDL_QUIT)
            return false;
        if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_CLOSE &&
            event.window.windowID == SDL_GetWindowID(gSdlWindow))
            return false;

        if (!ImGui::GetIO().WantCaptureKeyboard)
        {
            uint32_t bits = 0;
            if (event.type == SDL_KEYDOWN || event.type == SDL_KEYUP)
            {
                switch (event.key.keysym.sym)
                {
                case SDLK_LEFT:
                    bits = BTN_LEFT;
                    break;
                case SDLK_RIGHT:
                    bits = BTN_RIGHT;
                    break;
                case SDLK_UP:
                    bits = BTN_UP;
                    break;
                case SDLK_DOWN:
                    bits = BTN_DOWN;
                    break;
                case SDLK_1:
                    bits = BTN_START;
                    break;
                case SDLK_LSHIFT:
                    bits = BTN_BTN1;
                    break;
                case SDLK_z:
                    bits = BTN_BTN2;
                    break;
                case SDLK_x:
                    bits = BTN_BTN3;
                    break;
                case SDLK_c:
                    bits = BTN_BTN4;
                    break;
                }

                if (event.type == SDL_KEYDOWN)
                    gButtons |= bits;
                else
                    gButtons &= ~bits;
            }
        }
    }

    ImGui_ImplSDLRenderer2_NewFrame();
    ImGui_ImplSDL2_NewFrame();
    ImGui::NewFrame();

    if (ImGui::BeginMainMenuBar())
    {
        if (ImGui::BeginMenu("Windows"))
        {
            for (Window *window : Window::gWindows)
            {
                ImGui::MenuItem(window->mTitle.c_str(), nullptr, &window->mEnabled);
            }
            ImGui::EndMenu();
        }

        char status[128];
        snprintf(status, sizeof(status), "FPS: %.1f", ImGui::GetIO().Framerate);
        float width = ImGui::CalcTextSize(status).x + 5;
        ImGui::Dummy(ImVec2(ImGui::GetContentRegionAvail().x - width, 1));
        ImGui::TextUnformatted(status);
        ImGui::EndMainMenuBar();
    }

    for (Window *window : Window::gWindows)
    {
        window->Update();
    }

    return true;
}

uint32_t ImguiGetButtons()
{
    return gButtons;
}

void ImguiSetButtons(uint32_t buttons)
{
    gButtons = buttons;
}

void ImguiSetButtonBits(uint32_t bits)
{
    gButtons |= bits;
}

void ImguiClearButtonBits(uint32_t bits)
{
    gButtons &= ~bits;
}

void ImguiEndFrame()
{
    ImGui::Render();

    ImGuiIO &io = ImGui::GetIO();
    SDL_RenderSetScale(gSdlRenderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y);
    SDL_SetRenderDrawColor(gSdlRenderer, 0, 0, 0, 0);
    SDL_RenderClear(gSdlRenderer);
    ImGui_ImplSDLRenderer2_RenderDrawData(ImGui::GetDrawData(), gSdlRenderer);
    SDL_RenderPresent(gSdlRenderer);
}

SDL_Renderer *ImguiGetRenderer()
{
    return gSdlRenderer;
}

void ImguiSetTitle(const char *title)
{
    SDL_SetWindowTitle(gSdlWindow, title);
}

std::vector<Window *> Window::gWindows;
Window *Window::gHead = nullptr;

Window::Window(const char *name, ImGuiWindowFlags flags)
{
    mTitle = name;
    mEnabled = true;
    mFlags = flags;

    mNext = gHead;
    gHead = this;

    if (gWindows.size() > 0)
    {
        SortWindows();
    }
}

Window::~Window()
{
    // probably should clean up the linked list
}

void Window::Update()
{
    if (mEnabled)
    {
        if (ImGui::Begin(mTitle.c_str(), &mEnabled, mFlags))
        {
            Draw();
        }
        ImGui::End();
    }
}

void Window::SortWindows()
{
    gWindows.clear();
    Window *window = gHead;
    while (window)
    {
        gWindows.push_back(window);
        window = window->mNext;
    }

    std::sort(gWindows.begin(), gWindows.end(), [](auto a, auto b) { return a->mTitle < b->mTitle; });
}

void *Window::SettingsHandlerReadOpen(ImGuiContext *, ImGuiSettingsHandler *, const char *name)
{
    ImGuiID id = ImHashStr(name);

    for (Window *window : gWindows)
    {
        if (window->mTitle == name)
        {
            return window;
        }
    }

    return nullptr;
}

void Window::SettingsHandlerReadLine(ImGuiContext *, ImGuiSettingsHandler *, void *entry, const char *line)
{
    Window *window = (Window *)entry;
    int en;
    if (sscanf(line, "IsEnabled=%d", &en) == 1)
    {
        window->mEnabled = en != 0;
    }
}

void Window::SettingsHandlerWriteAll(ImGuiContext *, ImGuiSettingsHandler *handler, ImGuiTextBuffer *buf)
{
    // Write to text buffer
    for (Window *window : gWindows)
    {
        buf->appendf("[%s][%s]\n", handler->TypeName, window->mTitle.c_str());
        buf->appendf("IsEnabled=%d\n\n", window->mEnabled ? 1 : 0);
    }
}
