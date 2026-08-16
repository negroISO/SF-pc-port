#import <UIKit/UIKit.h>

#include <SDL.h>
#include <SDL_syswm.h>

#include "PsyX/PsyX_public.h"

namespace {

// The system normally retains connected scenes, but holding the exact scene
// registered by the host avoids guessing among UIApplication.connectedScenes.
// The host releases it explicitly by passing nullptr on scene disconnect.
__strong UIWindowScene *g_windowScene = nil;

} // namespace

extern "C" void PsyX_iOS_SetWindowScene(void *windowScene) {
  @autoreleasepool {
    g_windowScene = (__bridge UIWindowScene *)windowScene;
  }
}

extern "C" int PsyX_iOS_AttachWindowToScene(SDL_Window *window) {
  @autoreleasepool {
    if (!window) {
      SDL_SetError("PsyCross iOS scene bridge received a null SDL window");
      return 0;
    }

    UIWindowScene *windowScene = g_windowScene;
    if (!windowScene) {
      SDL_SetError("PsyCross iOS scene bridge has no registered UIWindowScene");
      return 0;
    }

    SDL_SysWMinfo windowInfo = {};
    SDL_VERSION(&windowInfo.version);
    if (!SDL_GetWindowWMInfo(window, &windowInfo)) {
      return 0;
    }
    if (windowInfo.subsystem != SDL_SYSWM_UIKIT ||
        !windowInfo.info.uikit.window) {
      SDL_SetError("SDL window does not expose a UIKit UIWindow");
      return 0;
    }

    UIWindow *nativeWindow = windowInfo.info.uikit.window;
    nativeWindow.windowScene = windowScene;
    [nativeWindow makeKeyAndVisible];
    if (nativeWindow.windowScene != windowScene) {
      SDL_SetError("UIKit did not retain the registered UIWindowScene");
      return 0;
    }
    return 1;
  }
}
