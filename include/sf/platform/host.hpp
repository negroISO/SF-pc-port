#pragma once

#include "sf/game/controller_bindings.hpp"
#include "sf/game/retail_cheats.hpp"
#include "sf/platform/player_input.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>

namespace sf::game {
class MissionPackage;
class TitleAssets;
class TitleMovies;
} // namespace sf::game

namespace sf::platform {

enum class AspectRatioMode {
  original_4_3,
  adaptive,
};

enum class ControllerProtocol {
  automatic,
  xinput,
  direct_input,
  raw_input,
};

using ControllerButtonBindings = game::ControllerButtonBindings;
inline constexpr auto controller_action_binding_count =
    game::controller_action_count;
using ControllerSettingsCommitCallback =
    std::function<bool(const ControllerButtonBindings &, bool vibration)>;

struct GraphicsSettings {
  int width{1280};
  int height{720};
  int msaa_samples{};
  bool bilinear_filtering{true};
  bool trilinear_filtering{true};
  bool anisotropic_filtering{true};
  bool smaa{true};
  bool volumetric_effects{};
  bool mission_skyboxes{true};
  AspectRatioMode aspect_ratio{AspectRatioMode::adaptive};
  bool vsync{true};
  std::uint32_t frame_limit{60U};
  bool fullscreen{};
  ControllerProtocol controller_protocol{ControllerProtocol::automatic};
  ControllerButtonBindings controller_bindings;
  bool controller_vibration{true};
};

enum class PsyCrossGuestFrameSmokeStatus : std::uint8_t {
  success,
  invalid_options,
  wrong_thread,
  missing_graphics_context,
  initial_presentation_invalid,
  guest_runtime_fault,
  presentation_invalid,
  visibility_timeout,
  renderer_rejected,
  framebuffer_incomplete,
  readback_failed,
  pixel_evidence_rejected,
};

struct PsyCrossGuestFrameSmokeOptions {
  // Keep this proof bounded independently from caller input. Forty-eight retail
  // ticks are 2.4 seconds of guest time and cover the opening fade without
  // turning the smoke into a lifecycle-driven gameplay loop.
  static constexpr std::uint32_t hard_maximum_guest_updates = 48U;

  std::uint32_t maximum_guest_updates{hard_maximum_guest_updates};
  std::uint8_t maximum_fade_intensity{32U};
};

struct PsyCrossGuestFrameSmokeResult {
  PsyCrossGuestFrameSmokeStatus status{
      PsyCrossGuestFrameSmokeStatus::renderer_rejected};
  std::uint32_t guest_updates{};
  std::uint64_t presentation_sequence{};
  std::uint64_t guest_frame{};
  std::uint8_t fade_intensity{0xffU};
  std::size_t presentation_models{};
  std::size_t active_objects{};
  std::size_t submitted_primitives{};
  std::size_t rejected_primitives{};
  int minimum_depth{};
  int maximum_depth{};
  int minimum_x{};
  int maximum_x{};
  int minimum_y{};
  int maximum_y{};
  std::uint32_t draw_framebuffer{};
  std::uint32_t read_framebuffer{};
  std::uint32_t framebuffer_status{};
  std::uint32_t renderer_gl_error{};
  std::uint32_t readback_gl_error{};
  std::uint32_t present_gl_error{};
  int viewport_x{};
  int viewport_y{};
  int viewport_width{};
  int viewport_height{};
  std::size_t pixel_count{};
  std::size_t opaque_pixel_count{};
  std::size_t nonuniform_pixel_count{};
  std::uint32_t unique_rgb_buckets{};
  std::uint8_t minimum_luminance{0xffU};
  std::uint8_t maximum_luminance{};
  std::array<std::uint8_t, 4U> lower_left_pixel{};
  std::array<std::uint8_t, 4U> center_pixel{};
  std::uint64_t pixel_hash{};
  bool coherent_presentation{};
  bool visibility_threshold_met{};
  bool observer_called{};

  [[nodiscard]] bool passed() const noexcept {
    return status == PsyCrossGuestFrameSmokeStatus::success;
  }
};

enum class PsyCrossGuestLoopSmokeStatus : std::uint8_t {
  success,
  invalid_options,
  wrong_thread,
  missing_graphics_context,
  initial_presentation_invalid,
  guest_runtime_fault,
  presentation_invalid,
  visibility_timeout,
  renderer_rejected,
  framebuffer_incomplete,
  readback_failed,
  pixel_evidence_rejected,
  terminated_early,
};

struct PsyCrossGuestLoopFrame {
  std::uint32_t presentation_index{};
  std::uint32_t updates{};
  std::uint64_t sequence{};
  std::uint64_t guest_frame{};
  std::size_t submitted{};
  std::size_t rejected{};
  double presentation_ms{};
  double interval_ms{};
};

struct PsyCrossGuestControllerSample {
  bool connected{};
  std::int32_t instance_id{-1};
  std::uint8_t controller_type{};
  std::string name;
  // Active-low PADRAW button bitmask: a zero bit means the button is held.
  std::uint16_t buttons{0xffffU};
  std::array<std::uint8_t, 4U> analog{128U, 128U, 128U, 128U};
  double move{};
  double turn{};
  double strafe{};
  bool aim{};
  bool fire{};
  bool interact{};
  double player_x{};
  double player_y{};
  double player_z{};
  int player_yaw{};
};

struct PsyCrossGuestLoopSmokeOptions {
  // Twenty presentations per second of guest time. Six hundred presentations
  // are thirty seconds of continuous paced execution, enough for the smoke to
  // exit by itself while devicectl captures the console.
  static constexpr std::uint32_t hard_maximum_presentations = 2400U;
  static constexpr std::uint32_t default_presentation_count = 600U;
  static constexpr double default_update_interval_seconds = 1.0 / 20.0;

  std::uint32_t presentation_count{default_presentation_count};
  double update_interval_seconds{default_update_interval_seconds};
  // Maximum empty-pad guest updates before the first visible presentation.
  std::uint32_t maximum_guest_updates{
      PsyCrossGuestFrameSmokeOptions::hard_maximum_guest_updates};
  std::uint8_t maximum_fade_intensity{32U};
  // Called once per loop iteration on the main thread so the host can service
  // its run loop. Required on iOS: UIKit cannot complete lifecycle
  // transitions while this loop blocks the main thread.
  std::function<void()> yield_to_host;
  // Optional observer invoked after each completed presentation, before the
  // present transaction, on the main thread.
  std::function<void(const PsyCrossGuestLoopFrame &)> per_presentation;
  // Optional observer for lifecycle transitions; `background` is true on
  // enter-background and false on enter-foreground.
  std::function<void(bool background, std::uint32_t presentation_index)>
      lifecycle_event;
  // When true, each guest update samples the physical SDL game controller
  // through the PsyX pad and feeds the mapped portable input into the guest.
  // The smoke registers its own pad buffer for the loop.
  bool sample_controller{};
  // Optional observer invoked once per presentation while sampling.
  std::function<void(const PsyCrossGuestControllerSample &)>
      controller_observer;
};

struct PsyCrossGuestLoopSmokeResult {
  PsyCrossGuestLoopSmokeStatus status{
      PsyCrossGuestLoopSmokeStatus::renderer_rejected};
  std::uint32_t presentations_completed{};
  std::uint32_t guest_updates_completed{};
  std::uint64_t first_sequence{};
  std::uint64_t last_sequence{};
  std::uint64_t first_guest_frame{};
  std::uint64_t last_guest_frame{};
  std::size_t submitted_primitives{};
  std::size_t rejected_primitives{};
  double first_presentation_ms{};
  double last_presentation_ms{};
  double minimum_interval_ms{};
  double maximum_interval_ms{};
  double mean_interval_ms{};
  std::uint32_t background_events{};
  std::uint32_t foreground_events{};
  std::uint32_t presentations_before_first_background{};
  double total_background_ms{};
  bool terminated_by_os{};
  bool visibility_threshold_met{};
  bool observer_called{};
  std::uint32_t renderer_gl_error{};
  std::uint32_t readback_gl_error{};
  std::uint32_t present_gl_error{};
  std::uint32_t draw_framebuffer{};
  std::uint32_t read_framebuffer{};
  std::uint32_t framebuffer_status{};
  int viewport_x{};
  int viewport_y{};
  int viewport_width{};
  int viewport_height{};
  std::size_t pixel_count{};
  std::size_t opaque_pixel_count{};
  std::size_t nonuniform_pixel_count{};
  std::uint32_t unique_rgb_buckets{};
  std::uint8_t minimum_luminance{0xffU};
  std::uint8_t maximum_luminance{};
  std::array<std::uint8_t, 4U> lower_left_pixel{};
  std::array<std::uint8_t, 4U> center_pixel{};
  std::uint64_t pixel_hash{};
  int minimum_depth{};
  int maximum_depth{};
  int minimum_x{};
  int maximum_x{};
  int minimum_y{};
  int maximum_y{};

  [[nodiscard]] bool passed() const noexcept {
    return status == PsyCrossGuestLoopSmokeStatus::success;
  }
};

class Host {
public:
  virtual ~Host() = default;
  Host(const Host &) = delete;
  Host &operator=(const Host &) = delete;

  virtual void run() = 0;

protected:
  Host() = default;
};

[[nodiscard]] std::unique_ptr<Host>
createPsyCrossHost(std::string title, GraphicsSettings graphics = {});

[[nodiscard]] std::unique_ptr<Host> createPsyCrossTitleHost(
    std::string title, game::TitleAssets assets, game::TitleMovies movies,
    game::MissionPackage initial_mission, std::filesystem::path cue_path,
    std::string supported_game_serial, GraphicsSettings graphics = {},
    KeyboardMouseBindings input = defaultKeyboardMouseBindings(),
    game::RetailCheatState cheats = {},
    ControllerSettingsCommitCallback controller_settings_commit = {});

[[nodiscard]] std::unique_ptr<Host> createPsyCrossSceneHost(
    std::string title, game::MissionPackage mission,
    std::filesystem::path cue_path, GraphicsSettings graphics = {},
    KeyboardMouseBindings input = defaultKeyboardMouseBindings(),
    game::RetailCheatState cheats = {},
    ControllerSettingsCommitCallback controller_settings_commit = {});

// Renders exactly one immutable guest presentation through the production
// PsyCross scene path. The caller owns SDL/PsyX initialization and must call on
// the main thread with the desired GL context current. The prepared mission and
// its authorized source must remain alive/accessible for the complete call.
// The caller must configure a single-sample render target before PsyX startup.
// This bounded path does not sample gameplay input, advance wall clocks, create
// audio/movie services, or enter the ordinary viewer loop.
[[nodiscard]] PsyCrossGuestFrameSmokeResult renderPsyCrossGuestFrameSmoke(
    const game::MissionPackage &mission,
    PsyCrossGuestFrameSmokeOptions options = {});

// Runs a bounded continuous lifecycle-owned guest loop through the production
// PsyCross scene path. The caller owns SDL/PsyX initialization and must call on
// the main thread with the desired GL context current. The prepared mission and
// its authorized source must remain alive/accessible for the complete call.
// The loop advances the guest with empty pad state at the authoritative 20 Hz
// rate, presents once per completed guest update, pauses on SDL lifecycle
// background events and resumes on foreground, and exits after
// `presentation_count` presentations or an OS termination event. Every
// iteration invokes `yield_to_host` so the host run loop stays responsive.
// This path does not sample gameplay input or create audio/movie services.
[[nodiscard]] PsyCrossGuestLoopSmokeResult runPsyCrossGuestLoopSmoke(
    const game::MissionPackage &mission,
    PsyCrossGuestLoopSmokeOptions options = {});

} // namespace sf::platform
