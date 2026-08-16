#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <OpenGLES/ES3/gl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <SDL2/SDL_system.h>

#include <PsyX/PsyX_public.h>

#include "sf/disc/disc_folder.hpp"
#include "sf/game/game_disc.hpp"
#include "sf/game/mission.hpp"
#include "sf/platform/host.hpp"

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <unistd.h>

namespace {

constexpr char kLogPrefix[] = "SF_GUEST_RENDER_SMOKE";
NSString *const kDiscFolderBookmarkKey = @"SFDiscFolderBookmark";
using SmokeClock = std::chrono::steady_clock;

struct DiscSource {
  NSURL *directoryURL = nil;
  std::optional<std::filesystem::path> expectedCue;
  bool securityScoped = false;
};

struct AsyncSmokeState {
  std::atomic_bool finished{false};
  bool passed = false;
};

double ElapsedMilliseconds(SmokeClock::time_point start) noexcept {
  return std::chrono::duration<double, std::milli>(SmokeClock::now() - start)
      .count();
}

void FinishSmoke(const std::shared_ptr<AsyncSmokeState> &state,
                 bool passed) noexcept {
  state->passed = passed;
  state->finished.store(true, std::memory_order_release);
}

void EvidenceLog(const char *format, ...) {
  std::fprintf(stderr, "%s ", kLogPrefix);
  va_list arguments;
  va_start(arguments, format);
  std::vfprintf(stderr, format, arguments);
  va_end(arguments);
  std::fputc('\n', stderr);
  std::fflush(stderr);
}

std::filesystem::path FileSystemPath(NSURL *url) {
  const char *representation = url.fileSystemRepresentation;
  if (!representation) {
    throw std::runtime_error{"URL has no file-system representation"};
  }
  return std::filesystem::path{representation};
}

bool IdentifiesSameFile(const std::filesystem::path &first,
                        const std::filesystem::path &second) {
  std::error_code error;
  const bool equivalent = std::filesystem::equivalent(first, second, error);
  return !error && equivalent;
}

NSURL *FileURL(const std::filesystem::path &path, BOOL isDirectory) {
  return [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                                        isDirectory:isDirectory
                                       relativeToURL:nil];
}

NSURL *TopLevelCueURL(NSURL *directoryURL) {
  NSError *listingError = nil;
  NSArray<NSURL *> *items = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:directoryURL
    includingPropertiesForKeys:@[ NSURLIsRegularFileKey,
                                   NSURLIsSymbolicLinkKey ]
                       options:0
                         error:&listingError];
  if (!items || listingError) {
    return nil;
  }

  NSMutableArray<NSURL *> *cueURLs = [[NSMutableArray alloc] init];
  for (NSURL *itemURL in items) {
    if ([itemURL.pathExtension caseInsensitiveCompare:@"cue"] !=
        NSOrderedSame) {
      continue;
    }
    NSError *resourceError = nil;
    NSDictionary<NSURLResourceKey, id> *values =
        [itemURL resourceValuesForKeys:@[ NSURLIsRegularFileKey,
                                          NSURLIsSymbolicLinkKey ]
                                 error:&resourceError];
    if (!values || resourceError ||
        [values[NSURLIsSymbolicLinkKey] boolValue]) {
      return nil;
    }
    if ([values[NSURLIsRegularFileKey] boolValue]) {
      [cueURLs addObject:itemURL];
    }
  }
  return cueURLs.count == 1U ? cueURLs.firstObject : nil;
}

// Read only enough coordinated CUE data to identify the child BIN that must
// be included in the final all-item access. The portable parser remains the
// authoritative validator while the directory, CUE, and BIN intents are held.
std::filesystem::path
CueBinaryReference(const std::filesystem::path &cuePath) {
  constexpr std::uintmax_t maximumCueSize = 1024U * 1024U;
  std::error_code typeError;
  const auto status = std::filesystem::symlink_status(cuePath, typeError);
  if (typeError || std::filesystem::is_symlink(status) ||
      !std::filesystem::is_regular_file(status)) {
    throw std::runtime_error{"CUE is not a regular file"};
  }

  std::error_code sizeError;
  const auto size = std::filesystem::file_size(cuePath, sizeError);
  if (sizeError || size > maximumCueSize) {
    throw std::runtime_error{"CUE cannot be inspected"};
  }

  std::ifstream stream{cuePath};
  if (!stream) {
    throw std::runtime_error{"CUE cannot be read"};
  }
  const std::regex filePattern{
      R"(^\s*FILE\s+\"([^\"]+)\"\s+BINARY\s*$)", std::regex::icase};
  std::optional<std::filesystem::path> reference;
  std::string line;
  while (std::getline(stream, line)) {
    std::smatch match;
    if (!std::regex_match(line, match, filePattern)) {
      continue;
    }
    if (reference) {
      throw std::runtime_error{"Multiple CUE binary references"};
    }
    reference = std::filesystem::path{match[1].str()};
  }
  if (!reference || reference->empty() || reference->is_absolute() ||
      reference->has_parent_path()) {
    throw std::runtime_error{"CUE binary is not a sibling filename"};
  }
  return *reference;
}

const char *StatusName(sf::platform::PsyCrossGuestFrameSmokeStatus status) {
  using Status = sf::platform::PsyCrossGuestFrameSmokeStatus;
  switch (status) {
  case Status::success:
    return "success";
  case Status::invalid_options:
    return "invalid_options";
  case Status::wrong_thread:
    return "wrong_thread";
  case Status::missing_graphics_context:
    return "missing_graphics_context";
  case Status::initial_presentation_invalid:
    return "initial_presentation_invalid";
  case Status::guest_runtime_fault:
    return "guest_runtime_fault";
  case Status::presentation_invalid:
    return "presentation_invalid";
  case Status::visibility_timeout:
    return "visibility_timeout";
  case Status::renderer_rejected:
    return "renderer_rejected";
  case Status::framebuffer_incomplete:
    return "framebuffer_incomplete";
  case Status::readback_failed:
    return "readback_failed";
  case Status::pixel_evidence_rejected:
    return "pixel_evidence_rejected";
  }
  return "unknown";
}

bool HasArgument(int argc, char *argv[], std::string_view expected) {
  for (int index = 1; index < argc; ++index) {
    if (argv[index] && expected == argv[index]) {
      return true;
    }
  }
  return false;
}

std::optional<std::filesystem::path> CueArgument(int argc, char *argv[]) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] && std::string_view{argv[index]} == "--sf-cue" &&
        argv[index + 1] && argv[index + 1][0] != '\0') {
      return std::filesystem::path{argv[index + 1]};
    }
  }
  return std::nullopt;
}

DiscSource ResolveDiscSource(int argc, char *argv[]) {
  if (const auto cue = CueArgument(argc, argv)) {
    NSURL *directory = [NSURL
        fileURLWithFileSystemRepresentation:cue->parent_path().c_str()
                                    isDirectory:YES
                                   relativeToURL:nil];
    if (!directory) {
      throw std::runtime_error{"Explicit CUE parent URL is unavailable"};
    }
    return {directory, cue, false};
  }

  NSData *bookmark = [[NSUserDefaults standardUserDefaults]
      dataForKey:kDiscFolderBookmarkKey];
  if (bookmark) {
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *directory =
        [NSURL URLByResolvingBookmarkData:bookmark
                                  options:0
                            relativeToURL:nil
                      bookmarkDataIsStale:&stale
                                    error:&error];
    if (!directory || error) {
      throw std::runtime_error{"Saved external folder is unavailable"};
    }
    if (![directory startAccessingSecurityScopedResource]) {
      throw std::runtime_error{"Saved external folder access was denied"};
    }
    EvidenceLog("disc_source result=PASS kind=security-scoped stale=%d",
                stale ? 1 : 0);
    return {directory, std::nullopt, true};
  }

  NSArray<NSURL *> *documents =
      [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                             inDomains:NSUserDomainMask];
  NSURL *directory =
      [documents.firstObject URLByAppendingPathComponent:@"Ps1"
                                             isDirectory:YES];
  if (!directory) {
    throw std::runtime_error{"Documents/Ps1 URL is unavailable"};
  }
  EvidenceLog("disc_source result=PASS kind=documents-ps1");
  return {directory, std::nullopt, false};
}

bool InitialiseRenderer() {
  if (![NSThread isMainThread]) {
    EvidenceLog("renderer_init result=FAIL reason=wrong-thread");
    return false;
  }

  const char *temporaryDirectory =
      [NSTemporaryDirectory() fileSystemRepresentation];
  if (!temporaryDirectory || chdir(temporaryDirectory) != 0) {
    EvidenceLog("renderer_init result=FAIL reason=temporary-cwd");
    return false;
  }

  SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
  g_cfg_msaaSamples = 0;
  g_cfg_bilinearFiltering = 1;
  g_cfg_trilinearFiltering = 0;
  g_cfg_anisotropicFiltering = 0;
  g_cfg_smaa = 0;
  g_cfg_volumetricEffects = 0;
  g_cfg_aspectMode = PSYX_ASPECT_ORIGINAL_4_3;
  g_cfg_renderWidth = 960;
  g_cfg_renderHeight = 540;
  g_cfg_swapInterval = 0;
  g_cfg_framebufferFeedback = 0;
  g_cfg_vblankThread = 0;

  char applicationName[] = "Syphon Filter Guest Renderer Smoke";
  PsyX_Initialise(applicationName, 960, 540, 0);
  SDL_Window *window = SDL_GL_GetCurrentWindow();
  if (!window || !SDL_GL_GetCurrentContext()) {
    EvidenceLog("renderer_init result=FAIL reason=missing-context");
    return false;
  }

  SDL_SysWMinfo windowInfo = {};
  SDL_VERSION(&windowInfo.version);
  if (!SDL_GetWindowWMInfo(window, &windowInfo) ||
      windowInfo.subsystem != SDL_SYSWM_UIKIT ||
      !windowInfo.info.uikit.window ||
      !windowInfo.info.uikit.window.windowScene) {
    EvidenceLog("renderer_init result=FAIL reason=scene-attachment");
    return false;
  }

  SDL_iPhoneSetEventPump(SDL_TRUE);
  PsyX_EnableSwapInterval(0);
  PsyX_SetFrameLimit(0);
  int drawableWidth = 0;
  int drawableHeight = 0;
  SDL_GL_GetDrawableSize(window, &drawableWidth, &drawableHeight);
  const GLubyte *version = glGetString(GL_VERSION);
  const GLubyte *renderer = glGetString(GL_RENDERER);
  EvidenceLog(
      "renderer_init result=PASS main_thread=1 scene_attached=1 "
      "drawable=%dx%d gl_version=%s gl_renderer=%s",
      drawableWidth, drawableHeight,
      version ? reinterpret_cast<const char *>(version) : "(null)",
      renderer ? reinterpret_cast<const char *>(renderer) : "(null)");
  return drawableWidth > 0 && drawableHeight > 0;
}

bool RunCoordinatedSmoke(const DiscSource &source) {
  if (![NSThread isMainThread]) {
    EvidenceLog("result=FAIL stage=coordination reason=wrong-thread");
    return false;
  }

  const auto smokeStart = SmokeClock::now();
  const auto state = std::make_shared<AsyncSmokeState>();
  NSOperationQueue *coordinationQueue = [[NSOperationQueue alloc] init];
  coordinationQueue.name = @"com.syphonfilter.port.guest-render-smoke";
  coordinationQueue.maxConcurrentOperationCount = 1;
  coordinationQueue.qualityOfService = NSQualityOfServiceUserInitiated;
  NSURL *directoryURL = source.directoryURL;
  const auto expectedCue = source.expectedCue;

  // The synchronous discovery coordinators deliberately run on this worker,
  // never on SDL/UIKit's main thread. The final all-item access is asynchronous
  // and keeps its intents held until the main-thread render has completed.
  [coordinationQueue addOperationWithBlock:^{
    @autoreleasepool {
      __block NSURL *cueURL = nil;
      NSFileCoordinator *directoryCoordinator =
          [[NSFileCoordinator alloc] initWithFilePresenter:nil];
      NSError *directoryError = nil;
      [directoryCoordinator
          coordinateReadingItemAtURL:directoryURL
                             options:NSFileCoordinatorReadingWithoutChanges
                               error:&directoryError
                          byAccessor:^(NSURL *coordinatedDirectoryURL) {
                            cueURL = TopLevelCueURL(coordinatedDirectoryURL);
                          }];
      if (directoryError || !cueURL) {
        EvidenceLog("result=FAIL stage=disc-intent-directory total_ms=%.3f",
                    ElapsedMilliseconds(smokeStart));
        FinishSmoke(state, false);
        return;
      }

      __block NSURL *binaryURL = nil;
      __block std::filesystem::path expectedBinaryReference;
      __block bool binaryReferenceReady = false;
      NSFileCoordinator *cueCoordinator =
          [[NSFileCoordinator alloc] initWithFilePresenter:nil];
      NSError *cueError = nil;
      [cueCoordinator
          coordinateReadingItemAtURL:cueURL
                             options:NSFileCoordinatorReadingWithoutChanges
                               error:&cueError
                          byAccessor:^(NSURL *coordinatedCueURL) {
                            try {
                              const auto cuePath =
                                  FileSystemPath(coordinatedCueURL);
                              if (expectedCue &&
                                  !IdentifiesSameFile(cuePath, *expectedCue)) {
                                throw std::runtime_error{
                                    "Explicit CUE does not match folder pair"};
                              }
                              expectedBinaryReference =
                                  CueBinaryReference(cuePath);
                              binaryURL = FileURL(
                                  cuePath.parent_path() /
                                      expectedBinaryReference,
                                  NO);
                              binaryReferenceReady = binaryURL != nil;
                            } catch (const std::exception &) {
                              binaryURL = nil;
                              binaryReferenceReady = false;
                            }
                          }];
      if (cueError || !binaryURL || !binaryReferenceReady) {
        EvidenceLog("result=FAIL stage=disc-intent-cue total_ms=%.3f",
                    ElapsedMilliseconds(smokeStart));
        FinishSmoke(state, false);
        return;
      }

      NSFileAccessIntent *directoryIntent = [NSFileAccessIntent
          readingIntentWithURL:directoryURL
                       options:NSFileCoordinatorReadingWithoutChanges];
      NSFileAccessIntent *cueIntent = [NSFileAccessIntent
          readingIntentWithURL:cueURL
                       options:NSFileCoordinatorReadingWithoutChanges];
      NSFileAccessIntent *binaryIntent = [NSFileAccessIntent
          readingIntentWithURL:binaryURL
                       options:NSFileCoordinatorReadingWithoutChanges];
      NSArray<NSFileAccessIntent *> *intents =
          @[ directoryIntent, cueIntent, binaryIntent ];
      NSFileCoordinator *coordinator =
          [[NSFileCoordinator alloc] initWithFilePresenter:nil];
      [coordinator
          coordinateAccessWithIntents:intents
                                 queue:coordinationQueue
                            byAccessor:^(NSError *coordinationError) {
                              @autoreleasepool {
                                if (coordinationError) {
                                  EvidenceLog(
                                      "result=FAIL stage=file-coordination "
                                      "total_ms=%.3f",
                                      ElapsedMilliseconds(smokeStart));
                                  FinishSmoke(state, false);
                                  return;
                                }

                                const char *failureStage = "disc validation";
                                try {
                                  const auto validationStart =
                                      SmokeClock::now();
                                  const auto coordinatedDirectoryPath =
                                      FileSystemPath(directoryIntent.URL);
                                  const auto coordinatedCuePath =
                                      FileSystemPath(cueIntent.URL);
                                  const auto coordinatedBinaryPath =
                                      FileSystemPath(binaryIntent.URL);
                                  if (CueBinaryReference(
                                          coordinatedCuePath) !=
                                      expectedBinaryReference) {
                                    throw std::runtime_error{
                                        "CUE companion changed"};
                                  }
                                  const auto pair =
                                      sf::disc::discoverCueBinPair(
                                          coordinatedDirectoryPath);
                                  if (!IdentifiesSameFile(
                                          pair.cue_path,
                                          coordinatedCuePath) ||
                                      !IdentifiesSameFile(
                                          pair.binary_path,
                                          coordinatedBinaryPath) ||
                                      (expectedCue &&
                                       !IdentifiesSameFile(pair.cue_path,
                                                           *expectedCue))) {
                                    throw std::runtime_error{
                                        "Coordinated disc pair changed"};
                                  }
                                  EvidenceLog(
                                      "disc_validation result=PASS "
                                      "step_ms=%.3f total_ms=%.3f",
                                      ElapsedMilliseconds(validationStart),
                                      ElapsedMilliseconds(smokeStart));

                                  failureStage = "disc open";
                                  const auto discOpenStart =
                                      SmokeClock::now();
                                  auto disc = sf::game::GameDisc::open(
                                      coordinatedCuePath);
                                  if (!disc.game()) {
                                    throw std::runtime_error{
                                        "Unsupported disc build"};
                                  }
                                  EvidenceLog(
                                      "disc_open result=PASS supported=1 "
                                      "step_ms=%.3f total_ms=%.3f",
                                      ElapsedMilliseconds(discOpenStart),
                                      ElapsedMilliseconds(smokeStart));

                                  failureStage = "mission load";
                                  const auto missionLoadStart =
                                      SmokeClock::now();
                                  auto mission =
                                      sf::game::MissionPackage::loadFirst(
                                          disc);
                                  EvidenceLog(
                                      "mission_load result=PASS index=1 "
                                      "step_ms=%.3f total_ms=%.3f",
                                      ElapsedMilliseconds(missionLoadStart),
                                      ElapsedMilliseconds(smokeStart));

                                  auto *missionPointer = &mission;
                                  __block bool renderPassed = false;
                                  const auto renderStart = SmokeClock::now();
                                  dispatch_sync(dispatch_get_main_queue(), ^{
                                    @autoreleasepool {
                                      try {
                                        if (!InitialiseRenderer()) {
                                          EvidenceLog(
                                              "result=FAIL "
                                              "stage=renderer-initialization "
                                              "render_ms=%.3f total_ms=%.3f",
                                              ElapsedMilliseconds(renderStart),
                                              ElapsedMilliseconds(smokeStart));
                                          return;
                                        }

                                        const auto result = sf::platform::
                                            renderPsyCrossGuestFrameSmoke(
                                                *missionPointer);
                                        EvidenceLog(
                                          "result=%s status=%s "
                                          "guest_updates=%u guest_frame=%llu "
                                          "sequence=%llu fade=%u models=%zu "
                                          "objects=%zu submitted=%zu "
                                          "rejected=%zu depth=%d:%d "
                                          "bounds=%d:%d,%d:%d fbo=%u "
                                          "read_fbo=%u fbo_status=0x%04x "
                                          "viewport=%d,%d,%dx%d pixels=%zu "
                                          "opaque=%zu nonuniform=%zu "
                                          "rgb_buckets=%u luminance=%u:%u "
                                          "gl_errors=0x%04x,0x%04x,0x%04x "
                                          "coherent=%d visible=%d observer=%d "
                                          "render_ms=%.3f total_ms=%.3f",
                                          result.passed() ? "PASS" : "FAIL",
                                          StatusName(result.status),
                                          result.guest_updates,
                                          static_cast<unsigned long long>(
                                              result.guest_frame),
                                          static_cast<unsigned long long>(
                                              result.presentation_sequence),
                                          result.fade_intensity,
                                          result.presentation_models,
                                          result.active_objects,
                                          result.submitted_primitives,
                                          result.rejected_primitives,
                                          result.minimum_depth,
                                          result.maximum_depth,
                                          result.minimum_x, result.maximum_x,
                                          result.minimum_y, result.maximum_y,
                                          result.draw_framebuffer,
                                          result.read_framebuffer,
                                          result.framebuffer_status,
                                          result.viewport_x,
                                          result.viewport_y,
                                          result.viewport_width,
                                          result.viewport_height,
                                          result.pixel_count,
                                          result.opaque_pixel_count,
                                          result.nonuniform_pixel_count,
                                          result.unique_rgb_buckets,
                                          result.minimum_luminance,
                                          result.maximum_luminance,
                                          result.renderer_gl_error,
                                          result.readback_gl_error,
                                          result.present_gl_error,
                                          result.coherent_presentation ? 1 : 0,
                                          result.visibility_threshold_met ? 1
                                                                          : 0,
                                          result.observer_called ? 1 : 0,
                                            ElapsedMilliseconds(renderStart),
                                            ElapsedMilliseconds(smokeStart));
                                        renderPassed = result.passed();
                                      } catch (const std::exception &) {
                                        EvidenceLog(
                                            "result=FAIL "
                                            "stage=bounded-guest-renderer "
                                            "render_ms=%.3f total_ms=%.3f",
                                            ElapsedMilliseconds(renderStart),
                                            ElapsedMilliseconds(smokeStart));
                                      }
                                    }
                                  });
                                  FinishSmoke(state, renderPassed);
                                } catch (const std::exception &) {
                                  // Provider/parser exceptions may include
                                  // retail paths. Evidence remains stage-only.
                                  EvidenceLog(
                                      "result=FAIL stage=%s total_ms=%.3f",
                                      failureStage,
                                      ElapsedMilliseconds(smokeStart));
                                  FinishSmoke(state, false);
                                }
                              }
                            }];
    }
  }];

  while (!state->finished.load(std::memory_order_acquire)) {
    @autoreleasepool {
      [[NSRunLoop currentRunLoop]
          runMode:NSDefaultRunLoopMode
       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  return state->passed;
}

} // namespace

int main(int argc, char *argv[]) {
  @autoreleasepool {
    if (!HasArgument(argc, argv, "--sf-run-guest-render-smoke")) {
      EvidenceLog("result=IDLE reason=explicit-launch-argument-required");
      return 0;
    }

    EvidenceLog("launch result=BEGIN owner=SDL-UIScene");
    std::optional<DiscSource> source;
    try {
      source = ResolveDiscSource(argc, argv);
      const bool passed = RunCoordinatedSmoke(*source);
      if (source->securityScoped) {
        [source->directoryURL stopAccessingSecurityScopedResource];
      }
      return passed ? 0 : 2;
    } catch (const std::exception &) {
      if (source && source->securityScoped) {
        [source->directoryURL stopAccessingSecurityScopedResource];
      }
      EvidenceLog("result=FAIL stage=disc-source");
      return 2;
    }
  }
}
