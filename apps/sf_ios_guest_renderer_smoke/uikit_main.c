#include <SDL2/SDL_main.h>

#if defined(__IPHONEOS__) || defined(__TVOS__)
#ifndef SDL_MAIN_HANDLED
#ifdef main
#undef main
#endif
int main(int argc, char *argv[]) { return SDL_UIKitRunApp(argc, argv, SDL_main); }
#endif
#endif
