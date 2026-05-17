#include "sim_core.h"
#include "sim_controller.h"
#include "sim_server.h"
#include "sim_ui.h"
#include "sim_video.h"
#include "sim_hierarchy.h"
#include "games.h"
#include "PGM.h"
#include "PGM___024root.h"
#include "imgui_wrap.h"
#include "sim_sdram.h"
#include "sim_ddr.h"
#include "verilated_fst_c.h"

#include "gfx_cache.h"

#include <cstdio>
#include <memory>
#include <SDL.h>

struct SimDebug
{
    uint32_t mModified;
    uint32_t mZoom;
    uint32_t mDy;
    uint32_t mY;
};

SimDebug *gSimDebugData = nullptr;

int main(int argc, char **argv)
{
    bool serverMode = false;
    std::string target;

    for (int i = 1; i < argc; i++)
    {
        std::string arg = argv[i];
        if (arg == "--server" || arg == "--control-stdio")
        {
            serverMode = true;
        }
        else if (!arg.empty() && arg[0] != '-')
        {
            target = arg;
        }
    }

    if (serverMode)
    {
        return RunServer(gSimController);
    }

    UiInit("PGM Simulator");

    auto initResult = gSimController.Initialize(false);
    if (!initResult.ok)
    {
        fprintf(stderr, "Failed to initialize simulator: %s\n", initResult.errorMessage.c_str());
        ImguiShutdown();
        return -1;
    }

    gSimDebugData = (SimDebug *)(gSimCore.mSDRAM->mData + 0x80000);

    if (target.empty())
    {
        target = "finalb";
    }

    if (target.length() > 4 && target.substr(target.length() - 4) == ".mra")
    {
        auto loadResult = gSimController.LoadMra(target);
        if (!loadResult.ok)
        {
            fprintf(stderr, "Failed to load MRA: %s\n", loadResult.errorMessage.c_str());
            gSimController.Shutdown();
            ImguiShutdown();
            return -1;
        }
    }
    else
    {
        auto loadResult = gSimController.LoadGame(target);
        if (!loadResult.ok)
        {
            fprintf(stderr, "Failed to load game: %s\n", loadResult.errorMessage.c_str());
            gSimController.Shutdown();
            ImguiShutdown();
            return -1;
        }
        gSimController.Reset(100);
    }

    UiInitWindows();
    UiGameChanged();

    const Uint8 *keyboardState = SDL_GetKeyboardState(NULL);
    bool screenshotKeyPressed = false;

    bool running = true;
    while (running)
    {
        gSimCore.mGfxCache->PruneCache();

        if (!UiBeginFrame())
        {
            running = false;
            break;
        }

        if (keyboardState && keyboardState[SDL_SCANCODE_F12] && !screenshotKeyPressed)
        {
            std::string filename = gSimCore.mVideo->GenerateScreenshotFilename("sim");
            gSimCore.mVideo->SaveScreenshot(filename.c_str());
            screenshotKeyPressed = true;
        }
        else if (keyboardState && !keyboardState[SDL_SCANCODE_F12])
        {
            screenshotKeyPressed = false;
        }

        gSimCore.mTop->pause = gSimCore.mSystemPause;
        gSimCore.mTop->joystick_p1 = ImguiGetButtons() & 0xffff;
        gSimCore.mTop->start = (ImguiGetButtons() >> 16) & 0xffff;
        gSimCore.mTop->coin = (ImguiGetButtons() >> 16) & 0xffff;

        if (gSimCore.mSimulationRun || gSimCore.mSimulationStep)
        {
            if (gSimCore.mSimulationStepVblank)
            {
                gSimCore.TickUntil([&] { return gSimCore.mTop->vblank == 0; }, 0);
                gSimCore.TickUntil([&] { return gSimCore.mTop->vblank != 0; }, 0);
            }
            else
            {
                gSimCore.Tick(gSimCore.mSimulationStepSize);
            }
            gSimCore.mVideo->UpdateTexture();
        }
        gSimCore.mSimulationStep = false;

        UiDraw();
        UiEndFrame();
    }

    gSimController.Shutdown();
    ImguiShutdown();
    return 0;
}
