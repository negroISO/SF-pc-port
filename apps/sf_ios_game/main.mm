#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>

#include "sf/game/game_disc.hpp"
#include "sf/game/mission.hpp"
#include "sf/game/title.hpp"
#include "sf/platform/host.hpp"

#include <SDL2/SDL_main.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr char kLogPrefix[] = "SF_IOS_GAME";
NSString *const kDiscFolderBookmarkKey = @"SFDiscFolderBookmark";
NSString *const kControllerVibrationKey = @"SFControllerVibration";
NSString *const kAspectRatioKey = @"SFGraphicsAspect";
NSString *const kControllerStickLayoutKey = @"SFControllerStickLayout";

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
  if (representation == nullptr) {
    throw std::runtime_error{"URL has no file-system representation"};
  }
  return std::filesystem::path{representation};
}

NSString *NSStringFromStringView(std::string_view value) {
  return [[NSString alloc] initWithBytes:value.data()
                                  length:value.size()
                                encoding:NSUTF8StringEncoding];
}

NSURL *TopLevelCueURL(NSURL *directoryURL) {
  NSError *listingError = nil;
  NSArray<NSURL *> *items = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:directoryURL
    includingPropertiesForKeys:@[ NSURLIsRegularFileKey,
                                   NSURLIsSymbolicLinkKey ]
                       options:0
                         error:&listingError];
  if (items == nil || listingError != nil) {
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
    if (values == nil || resourceError != nil ||
        [values[NSURLIsSymbolicLinkKey] boolValue]) {
      return nil;
    }
    if ([values[NSURLIsRegularFileKey] boolValue]) {
      [cueURLs addObject:itemURL];
    }
  }
  return cueURLs.count == 1U ? cueURLs.firstObject : nil;
}

struct DiscLease {
  NSURL *directoryURL = nil;
  NSURL *cueURL = nil;
  bool securityScoped = false;

  ~DiscLease() {
    if (securityScoped) {
      [directoryURL stopAccessingSecurityScopedResource];
    }
  }
};

DiscLease ResolveDiscLease() {
  NSData *bookmark = [[NSUserDefaults standardUserDefaults]
      dataForKey:kDiscFolderBookmarkKey];
  if (bookmark == nil) {
    throw std::runtime_error{"No external disc folder bookmark"};
  }

  BOOL stale = NO;
  NSError *error = nil;
  NSURL *directory = [NSURL URLByResolvingBookmarkData:bookmark
                                                options:0
                                            relativeToURL:nil
                                      bookmarkDataIsStale:&stale
                                                    error:&error];
  if (directory == nil || error != nil) {
    throw std::runtime_error{"Saved external disc folder is unavailable"};
  }

  DiscLease lease;
  lease.directoryURL = directory;
  lease.securityScoped = [directory startAccessingSecurityScopedResource];
  if (!lease.securityScoped) {
    throw std::runtime_error{"External disc folder access was denied"};
  }
  lease.cueURL = TopLevelCueURL(directory);
  if (lease.cueURL == nil) {
    throw std::runtime_error{"External folder has no unique CUE/BIN pair"};
  }
  EvidenceLog("disc_source result=PASS stale=%d", stale ? 1 : 0);
  return lease;
}

bool WaitForPhysicalControllerPreflight(double settle_seconds) {
  @autoreleasepool {
    EvidenceLog("gc_preflight begin settle_seconds=%.3f", settle_seconds);
    __block bool discovered = [GCController controllers].count != 0;
    __block id connect_token = [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidConnectNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  GCController *controller = note.object;
                  discovered = YES;
                  EvidenceLog(
                      "gc_preflight connect name=%s category=%s",
                      controller.vendorName.UTF8String
                          ? controller.vendorName.UTF8String
                          : "(null)",
                      controller.productCategory.UTF8String
                          ? controller.productCategory.UTF8String
                          : "(null)");
                }];
    NSTimer *poll_timer = [NSTimer
        timerWithTimeInterval:0.5
                     repeats:YES
                       block:^(NSTimer *timer) {
                         (void)timer;
                         discovered = [GCController controllers].count != 0;
                       }];
    [[NSRunLoop currentRunLoop] addTimer:poll_timer
                                    forMode:NSRunLoopCommonModes];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:settle_seconds];
    while (!discovered && [deadline timeIntervalSinceNow] > 0.0) {
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    [poll_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:connect_token];
    EvidenceLog("gc_preflight end count=%lu discovered=%d",
                static_cast<unsigned long>([GCController controllers].count),
                discovered ? 1 : 0);
    return discovered;
  }
}

sf::game::ControllerButtonBindings LoadControllerBindings() {
  sf::game::ControllerButtonBindings bindings;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  for (const auto &metadata : sf::game::controllerActionCatalog()) {
    NSString *key = NSStringFromStringView(metadata.config_key);
    NSNumber *value = [defaults objectForKey:key];
    if (value != nil) {
      bindings[metadata.action] = static_cast<std::uint32_t>(
          value.unsignedIntValue);
    }
  }
  NSNumber *layout = [defaults objectForKey:kControllerStickLayoutKey];
  if (layout != nil) {
    bindings.stick_layout = static_cast<sf::game::ControllerStickLayout>(
        layout.intValue);
  }
  if (!sf::game::areControllerBindingsValid(bindings)) {
    EvidenceLog("controller_settings result=RESET reason=invalid");
    return {};
  }
  return bindings;
}

bool StoreControllerBindings(
    const sf::platform::ControllerButtonBindings &bindings,
    bool vibration) {
  if (!sf::game::areControllerBindingsValid(bindings)) {
    return false;
  }
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  for (const auto &metadata : sf::game::controllerActionCatalog()) {
    [defaults setObject:@(bindings[metadata.action])
                 forKey:NSStringFromStringView(metadata.config_key)];
  }
  [defaults setInteger:static_cast<NSInteger>(bindings.stick_layout)
                 forKey:kControllerStickLayoutKey];
  [defaults setBool:vibration forKey:kControllerVibrationKey];
  return [defaults synchronize];
}

sf::platform::GraphicsSettings
LoadGraphicsSettings(const std::vector<std::string_view> &arguments) {
  sf::platform::GraphicsSettings settings;
  settings.width = 1280;
  settings.height = 720;
  settings.msaa_samples = 0;
  settings.bilinear_filtering = true;
  settings.trilinear_filtering = false;
  settings.anisotropic_filtering = false;
  settings.smaa = false;
  settings.volumetric_effects = false;
  settings.mission_skyboxes = false;
  settings.vsync = true;
  settings.frame_limit = 60U;
  settings.fullscreen = true;
  settings.controller_bindings = LoadControllerBindings();
  settings.controller_vibration =
      [NSUserDefaults.standardUserDefaults objectForKey:
            kControllerVibrationKey] == nil ||
      [NSUserDefaults.standardUserDefaults boolForKey:
            kControllerVibrationKey];
  settings.aspect_ratio = sf::platform::AspectRatioMode::original_4_3;
  if ([NSUserDefaults.standardUserDefaults objectForKey:kAspectRatioKey] != nil &&
      [NSUserDefaults.standardUserDefaults integerForKey:kAspectRatioKey] == 0) {
    settings.aspect_ratio = sf::platform::AspectRatioMode::adaptive;
  }
  if (std::find(arguments.begin(), arguments.end(), "--sf-aspect-adaptive") !=
      arguments.end()) {
    settings.aspect_ratio = sf::platform::AspectRatioMode::adaptive;
  }
  if (std::find(arguments.begin(), arguments.end(), "--sf-aspect-4-3") !=
      arguments.end()) {
    settings.aspect_ratio = sf::platform::AspectRatioMode::original_4_3;
  }
  return settings;
}

} // namespace

int main(int argc, char *argv[]) {
  @autoreleasepool {
    try {
      const std::vector<std::string_view> arguments(
          argv + (argc > 0 ? 1 : 0), argv + argc);
      EvidenceLog("launch result=BEGIN mode=full-title owner=SDL-UIScene");
      if (!WaitForPhysicalControllerPreflight(120.0)) {
        EvidenceLog("result=FAIL stage=controller-preflight "
                    "reason=no-physical-controller");
        return 2;
      }

      const DiscLease disc_lease = ResolveDiscLease();
      const auto cue_path = FileSystemPath(disc_lease.cueURL);
      auto disc = sf::game::GameDisc::open(cue_path);
      if (!disc.game()) {
        EvidenceLog("result=FAIL stage=disc-open reason=unsupported-build");
        return 2;
      }

      const auto save_location = sf::game::defaultTitleSaveLocation(
          cue_path, disc.game()->serial);
      EvidenceLog("save_file path=%s",
                  save_location.primary.string().c_str());

      auto assets = sf::game::TitleAssets::load(disc);
      auto movies = sf::game::TitleMovies::load(disc);
      auto mission = sf::game::MissionPackage::loadFirst(disc);
      auto graphics = LoadGraphicsSettings(arguments);
      auto host = sf::platform::createPsyCrossTitleHost(
          "Syphon Filter", std::move(assets), std::move(movies),
          std::move(mission), cue_path, std::string{disc.game()->serial},
          graphics, sf::platform::defaultKeyboardMouseBindings(), {},
          StoreControllerBindings);
      EvidenceLog("title_host result=BEGIN");
      host->run();
      EvidenceLog("title_host result=END");
      return 0;
    } catch (const std::exception &error) {
      EvidenceLog("result=FAIL stage=startup reason=%s", error.what());
      return 1;
    }
  }
}
