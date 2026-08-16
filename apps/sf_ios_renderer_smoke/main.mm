#import <UIKit/UIKit.h>

#include <OpenGLES/ES3/gl.h>
#define SDL_MAIN_HANDLED 1
#include <SDL.h>
#include <SDL_syswm.h>
#include <SDL_system.h>

#include "PsyX/PsyX_public.h"

#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <unistd.h>

namespace {

constexpr char kLogPrefix[] = "SF_RENDER_SMOKE";

struct SmokeVertex {
  GLfloat position[2];
  GLfloat color[3];
};

struct SmokeState {
  SDL_Window *window = nullptr;
  GLuint program = 0;
  GLuint vertexArray = 0;
  GLuint vertexBuffer = 0;
  int renderWidth = 0;
  int renderHeight = 0;
  std::uint64_t frame = 0;
  bool resultLogged = false;
};

SmokeState g_state;

void EvidenceLog(const char *message) {
  std::fprintf(stderr, "%s\n", message);
  std::fflush(stderr);
}

const char *SafeGLString(GLenum name) {
  const GLubyte *value = glGetString(name);
  return value ? reinterpret_cast<const char *>(value) : "(null)";
}

bool DrainGLErrors(const char *stage) {
  bool clean = true;
  for (int count = 0; count < 16; ++count) {
    const GLenum error = glGetError();
    if (error == GL_NO_ERROR) {
      break;
    }
    clean = false;
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s gl_error stage=%s value=0x%04x", kLogPrefix, stage,
                 static_cast<unsigned int>(error));
  }
  return clean;
}

GLuint CompileShader(GLenum type, const char *source, const char *label) {
  const GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);

  GLint compiled = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
  if (compiled == GL_TRUE) {
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                "%s shader_compile label=%s result=PASS", kLogPrefix,
                label);
    return shader;
  }

  GLchar log[2048] = {};
  GLsizei length = 0;
  glGetShaderInfoLog(shader, static_cast<GLsizei>(sizeof(log)), &length, log);
  SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
               "%s shader_compile label=%s result=FAIL log=%.*s", kLogPrefix,
               label, static_cast<int>(length), log);
  glDeleteShader(shader);
  return 0;
}

bool CreateTrianglePipeline() {
  static constexpr char kVertexShader[] = R"glsl(#version 300 es
precision highp float;
layout(location = 0) in vec2 a_position;
layout(location = 1) in vec3 a_color;
out lowp vec3 v_color;
void main() {
  v_color = a_color;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
)glsl";

  static constexpr char kFragmentShader[] = R"glsl(#version 300 es
precision highp float;
in lowp vec3 v_color;
layout(location = 0) out lowp vec4 o_color;
void main() {
  o_color = vec4(v_color, 1.0);
}
)glsl";

  const GLuint vertexShader =
      CompileShader(GL_VERTEX_SHADER, kVertexShader, "vertex");
  const GLuint fragmentShader =
      CompileShader(GL_FRAGMENT_SHADER, kFragmentShader, "fragment");
  if (!vertexShader || !fragmentShader) {
    if (vertexShader) {
      glDeleteShader(vertexShader);
    }
    if (fragmentShader) {
      glDeleteShader(fragmentShader);
    }
    return false;
  }

  g_state.program = glCreateProgram();
  glAttachShader(g_state.program, vertexShader);
  glAttachShader(g_state.program, fragmentShader);
  glLinkProgram(g_state.program);
  glDeleteShader(vertexShader);
  glDeleteShader(fragmentShader);

  GLint linked = GL_FALSE;
  glGetProgramiv(g_state.program, GL_LINK_STATUS, &linked);
  if (linked != GL_TRUE) {
    GLchar log[2048] = {};
    GLsizei length = 0;
    glGetProgramInfoLog(g_state.program, static_cast<GLsizei>(sizeof(log)),
                        &length, log);
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s program_link result=FAIL log=%.*s", kLogPrefix,
                 static_cast<int>(length), log);
    glDeleteProgram(g_state.program);
    g_state.program = 0;
    return false;
  }
  SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "%s program_link result=PASS",
              kLogPrefix);

  static constexpr SmokeVertex kVertices[] = {
      {{-0.82f, -0.72f}, {1.0f, 0.04f, 0.04f}},
      {{0.82f, -0.72f}, {0.04f, 1.0f, 0.04f}},
      {{0.0f, 0.82f}, {0.04f, 0.12f, 1.0f}},
  };

  glGenVertexArrays(1, &g_state.vertexArray);
  glBindVertexArray(g_state.vertexArray);
  glGenBuffers(1, &g_state.vertexBuffer);
  glBindBuffer(GL_ARRAY_BUFFER, g_state.vertexBuffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(kVertices), kVertices, GL_STATIC_DRAW);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(SmokeVertex),
                        reinterpret_cast<const void *>(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(
      1, 3, GL_FLOAT, GL_FALSE, sizeof(SmokeVertex),
      reinterpret_cast<const void *>(offsetof(SmokeVertex, color)));
  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  return DrainGLErrors("pipeline_setup");
}

bool ValidateKnownFrame() {
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glFinish();

  GLubyte background[4] = {};
  GLubyte center[4] = {};
  glReadPixels(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, background);
  glReadPixels(g_state.renderWidth / 2, g_state.renderHeight / 2, 1, 1,
               GL_RGBA, GL_UNSIGNED_BYTE, center);
  const bool clean = DrainGLErrors("known_frame_readback");

  const bool backgroundMatches = background[0] <= 8 && background[1] <= 12 &&
                                 background[2] <= 16 && background[3] >= 240;
  const bool centerMatches = center[0] >= 24 && center[1] >= 24 &&
                             center[2] >= 24 && center[3] >= 240;
  const bool passed = clean && backgroundMatches && centerMatches;

  SDL_LogInfo(
      SDL_LOG_CATEGORY_APPLICATION,
      "%s known_frame result=%s background=%u,%u,%u,%u center=%u,%u,%u,%u",
      kLogPrefix, passed ? "PASS" : "FAIL", background[0], background[1],
      background[2], background[3], center[0], center[1], center[2],
      center[3]);
  char evidence[256] = {};
  std::snprintf(
      evidence, sizeof(evidence),
      "%s known_frame result=%s background=%u,%u,%u,%u center=%u,%u,%u,%u",
      kLogPrefix, passed ? "PASS" : "FAIL", background[0], background[1],
      background[2], background[3], center[0], center[1], center[2], center[3]);
  EvidenceLog(evidence);
  return passed;
}

void SDLCALL RenderFrame(void *) {
  ++g_state.frame;
  if (!PsyX_BeginScene()) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s begin_scene result=FAIL frame=%llu", kLogPrefix,
                 static_cast<unsigned long long>(g_state.frame));
    return;
  }

  GLint drawFramebuffer = 0;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
  const GLenum framebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);

  glViewport(0, 0, g_state.renderWidth, g_state.renderHeight);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_CULL_FACE);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glDepthMask(GL_FALSE);
  glClearColor(4.0f / 255.0f, 8.0f / 255.0f, 12.0f / 255.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glUseProgram(g_state.program);
  glBindVertexArray(g_state.vertexArray);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glBindVertexArray(0);
  glUseProgram(0);

  const bool drawClean = DrainGLErrors("draw");
  const bool knownFrame = g_state.frame == 1 ? ValidateKnownFrame() : true;

  PsyX_EndScene();

  GLint presentedFramebuffer = 0;
  GLint presentedRenderbuffer = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &presentedFramebuffer);
  glGetIntegerv(GL_RENDERBUFFER_BINDING, &presentedRenderbuffer);
  const bool presentClean = DrainGLErrors("present");
  const bool fboComplete = framebufferStatus == GL_FRAMEBUFFER_COMPLETE;
  const bool drawableBindings =
      presentedFramebuffer != 0 && presentedRenderbuffer != 0;
  const bool framePassed = fboComplete && drawFramebuffer != 0 && drawClean &&
                           knownFrame && drawableBindings && presentClean;

  if (!g_state.resultLogged) {
    SDL_LogInfo(
        SDL_LOG_CATEGORY_APPLICATION,
        "%s result=%s frame=%llu native_fbo=%d native_status=0x%04x "
        "present_fbo=%d present_rbo=%d drawable=%dx%d",
        kLogPrefix, framePassed ? "PASS" : "FAIL",
        static_cast<unsigned long long>(g_state.frame), drawFramebuffer,
        static_cast<unsigned int>(framebufferStatus), presentedFramebuffer,
        presentedRenderbuffer, g_state.renderWidth, g_state.renderHeight);
    char evidence[320] = {};
    std::snprintf(
        evidence, sizeof(evidence),
        "%s result=%s frame=%llu native_fbo=%d native_status=0x%04x "
        "present_fbo=%d present_rbo=%d drawable=%dx%d",
        kLogPrefix, framePassed ? "PASS" : "FAIL",
        static_cast<unsigned long long>(g_state.frame), drawFramebuffer,
        static_cast<unsigned int>(framebufferStatus), presentedFramebuffer,
        presentedRenderbuffer, g_state.renderWidth, g_state.renderHeight);
    EvidenceLog(evidence);
    g_state.resultLogged = true;
  } else if (g_state.frame == 120) {
    SDL_LogInfo(
        SDL_LOG_CATEGORY_APPLICATION,
        "%s heartbeat result=%s frame=%llu native_fbo=%d "
        "native_status=0x%04x present_fbo=%d present_rbo=%d",
        kLogPrefix, framePassed ? "PASS" : "FAIL",
        static_cast<unsigned long long>(g_state.frame), drawFramebuffer,
        static_cast<unsigned int>(framebufferStatus), presentedFramebuffer,
        presentedRenderbuffer);
  }
}

bool InitialiseSmoke(UIWindowScene *windowScene, UIWindow **nativeWindowOut) {
  SDL_SetMainReady();
  SDL_iPhoneSetEventPump(SDL_TRUE);
  PsyX_iOS_SetWindowScene((__bridge void *)windowScene);

  SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
  SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "%s launch", kLogPrefix);
  EvidenceLog("SF_RENDER_SMOKE launch lifecycle=UIScene");

  const char *temporaryDirectory =
      [NSTemporaryDirectory() fileSystemRepresentation];
  if (temporaryDirectory && chdir(temporaryDirectory) == 0) {
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "%s cwd=%s", kLogPrefix,
                temporaryDirectory);
  } else {
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                "%s cwd_temp result=FAIL", kLogPrefix);
  }

  if (SDL_Init(SDL_INIT_VIDEO) != 0) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s sdl_video_init result=FAIL error=%s", kLogPrefix,
                 SDL_GetError());
    return false;
  }

  SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
  SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0);
  SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 0);

  g_cfg_framebufferFeedback = 0;
  g_cfg_vblankThread = 0;
  g_cfg_msaaSamples = 0;
  g_cfg_smaa = 0;
  g_cfg_volumetricEffects = 0;
  g_cfg_aspectMode = PSYX_ASPECT_ADAPTIVE;
  g_cfg_renderWidth = 0;
  g_cfg_renderHeight = 0;

  char applicationName[] = "PsyCross Renderer Smoke";
  PsyX_Initialise(applicationName, 960, 540, 0);

  g_state.window = SDL_GL_GetCurrentWindow();
  if (!g_state.window || !SDL_GL_GetCurrentContext()) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s psycross_init result=FAIL sdl_error=%s", kLogPrefix,
                 SDL_GetError());
    return false;
  }

  SDL_SysWMinfo windowInfo = {};
  SDL_VERSION(&windowInfo.version);
  if (!SDL_GetWindowWMInfo(g_state.window, &windowInfo) ||
      windowInfo.subsystem != SDL_SYSWM_UIKIT ||
      !windowInfo.info.uikit.window) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s native_window result=FAIL error=%s", kLogPrefix,
                 SDL_GetError());
    return false;
  }
  UIWindow *nativeWindow = windowInfo.info.uikit.window;
  if (nativeWindow.windowScene != windowScene) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s scene_attachment result=FAIL", kLogPrefix);
    return false;
  }
  if (nativeWindowOut) {
    *nativeWindowOut = nativeWindow;
  }

  SDL_GL_GetDrawableSize(g_state.window, &g_state.renderWidth,
                         &g_state.renderHeight);
  if (g_state.renderWidth <= 0 || g_state.renderHeight <= 0) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s drawable_size result=FAIL size=%dx%d", kLogPrefix,
                 g_state.renderWidth, g_state.renderHeight);
    return false;
  }
  g_cfg_renderWidth = g_state.renderWidth;
  g_cfg_renderHeight = g_state.renderHeight;

  GLint initialFramebuffer = 0;
  GLint initialRenderbuffer = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &initialFramebuffer);
  glGetIntegerv(GL_RENDERBUFFER_BINDING, &initialRenderbuffer);
  SDL_LogInfo(
      SDL_LOG_CATEGORY_APPLICATION,
      "%s context vendor=%s renderer=%s version=%s glsl=%s drawable=%dx%d "
      "initial_fbo=%d initial_rbo=%d",
      kLogPrefix, SafeGLString(GL_VENDOR), SafeGLString(GL_RENDERER),
      SafeGLString(GL_VERSION), SafeGLString(GL_SHADING_LANGUAGE_VERSION),
      g_state.renderWidth, g_state.renderHeight, initialFramebuffer,
      initialRenderbuffer);
  char contextEvidence[512] = {};
  std::snprintf(
      contextEvidence, sizeof(contextEvidence),
      "%s context version=%s glsl=%s drawable=%dx%d initial_fbo=%d "
      "initial_rbo=%d scene_attached=1",
      kLogPrefix, SafeGLString(GL_VERSION),
      SafeGLString(GL_SHADING_LANGUAGE_VERSION), g_state.renderWidth,
      g_state.renderHeight, initialFramebuffer, initialRenderbuffer);
  EvidenceLog(contextEvidence);

  if (!DrainGLErrors("psycross_init") || !CreateTrianglePipeline()) {
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "%s setup result=FAIL", kLogPrefix);
    return false;
  }

  SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
              "%s setup result=PASS callback=scene-CADisplayLink", kLogPrefix);
  EvidenceLog("SF_RENDER_SMOKE setup result=PASS callback=scene-CADisplayLink");
  return true;
}

} // namespace

@interface SFRendererSmokeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@interface SFRendererSmokeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) CADisplayLink *displayLink;
@end

@implementation SFRendererSmokeAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  (void)application;
  (void)launchOptions;
  EvidenceLog("SF_RENDER_SMOKE app_did_finish lifecycle=UIScene");
  return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
  (void)application;
  (void)options;
  UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
      initWithName:@"Renderer Smoke"
       sessionRole:session.role];
  configuration.delegateClass = SFRendererSmokeSceneDelegate.class;
  return configuration;
}

@end

@implementation SFRendererSmokeSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
  (void)session;
  (void)connectionOptions;
  if (![scene isKindOfClass:UIWindowScene.class]) {
    EvidenceLog("SF_RENDER_SMOKE scene_connect result=FAIL type");
    return;
  }

  EvidenceLog("SF_RENDER_SMOKE scene_will_connect");
  UIWindow *nativeWindow = nil;
  if (!InitialiseSmoke((UIWindowScene *)scene, &nativeWindow)) {
    EvidenceLog("SF_RENDER_SMOKE setup result=FAIL");
    return;
  }

  self.window = nativeWindow;
  self.displayLink =
      [CADisplayLink displayLinkWithTarget:self selector:@selector(drawFrame:)];
  self.displayLink.paused = YES;
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop
                         forMode:NSRunLoopCommonModes];
}

- (void)drawFrame:(CADisplayLink *)displayLink {
  (void)displayLink;
  RenderFrame(nullptr);
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
  (void)scene;
  self.displayLink.paused = NO;
  SDL_iPhoneSetEventPump(SDL_TRUE);
  EvidenceLog("SF_RENDER_SMOKE scene_active");
}

- (void)sceneWillResignActive:(UIScene *)scene {
  (void)scene;
  self.displayLink.paused = YES;
  EvidenceLog("SF_RENDER_SMOKE scene_inactive");
}

- (void)sceneDidDisconnect:(UIScene *)scene {
  (void)scene;
  [self.displayLink invalidate];
  self.displayLink = nil;
  if (g_state.window) {
    PsyX_Shutdown();
    g_state = {};
  }
  PsyX_iOS_SetWindowScene(nullptr);
  SDL_iPhoneSetEventPump(SDL_FALSE);
  EvidenceLog("SF_RENDER_SMOKE scene_disconnected");
}

@end

#ifdef main
#undef main
#endif

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(
        argc, argv, nil, NSStringFromClass(SFRendererSmokeAppDelegate.class));
  }
}
