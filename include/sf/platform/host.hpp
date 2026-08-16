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

} // namespace sf::platform
