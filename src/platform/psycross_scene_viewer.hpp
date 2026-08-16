#pragma once

#include "sf/game/campaign.hpp"
#include "sf/game/pause_menu.hpp"
#include "sf/platform/host.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>

struct PADRAW;

namespace sf::game {
class GameplaySession;
class MissionPackage;
} // namespace sf::game

namespace sf::platform::detail {

class PsyCrossAudioOutput;

enum class SceneExitReason {
  exit_application,
  return_to_title,
  mission_complete,
  mission_selected,
  bounded_presentation_complete,
  bounded_presentation_rejected,
  continuous_loop_complete,
  continuous_loop_terminated,
  continuous_loop_guest_fault,
  continuous_loop_presentation_invalid,
};
[[nodiscard]] InputPromptBindings
titleControllerInputPromptBindings(int controller_family);

struct SceneViewerResult {
  std::uint16_t previous_buttons{0xffffU};
  SceneExitReason reason{SceneExitReason::exit_application};
  std::optional<std::uint32_t> selected_mission;
  std::optional<game::CampaignCarryState> carry;
};

struct SceneFrameSubmission {
  std::uint64_t sequence{};
  std::uint64_t guest_frame{};
  std::size_t submitted{};
  std::size_t rejected{};
  int minimum_depth{};
  int maximum_depth{};
  int minimum_x{};
  int maximum_x{};
  int minimum_y{};
  int maximum_y{};
};

struct SceneLoopPresentation {
  std::uint32_t presentation_index{};
  std::uint32_t updates{};
  double presentation_ms{};
  double interval_ms{};
  SceneFrameSubmission submission;
};

struct SceneControllerSample {
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

struct SceneViewerContinuousGuestLoopOptions {
  std::uint32_t presentation_count{};
  double update_interval_seconds{1.0 / 20.0};
  // Called once per loop iteration on the caller's thread so the host can
  // service its run loop; required for UIKit lifecycle transitions on iOS.
  std::function<void()> yield_to_host;
  // Called after each completed presentation before the present transaction.
  // Return false to stop the loop early.
  std::function<bool(const SceneLoopPresentation &)> per_presentation;
  // Called on lifecycle transitions: `background` is true on enter-background
  // and false on enter-foreground; the presentation index is the count of
  // completed presentations when the transition was observed.
  std::function<void(bool background, std::uint32_t presentation_index)>
      lifecycle_event;
  // When true, each guest update samples the physical SDL game controller
  // through PsyX/PADRAW and feeds the mapped portable input into the guest.
  // The pad must be registered (PadInitDirect) before the loop runs.
  bool sample_controller{};
  // Invoked once per presentation when sample_controller is enabled, after
  // the guest update, with the raw pad state, mapped input and guest pose.
  std::function<void(const SceneControllerSample &)> controller_observer;
};

struct SceneViewerRunOptions {
  bool present_preloaded_frame_once{};
  std::uint64_t expected_sequence{};
  std::uint64_t expected_guest_frame{};
  std::function<void(const SceneFrameSubmission &)> before_end_scene;
  std::optional<SceneViewerContinuousGuestLoopOptions> continuous_guest_loop;
};

// Uses the same retail INTRFACE font page and ACD primitive path as the
// in-game pause screen. Keeping mission-complete UI on this renderer avoids
// PsyCross's debug-font VRAM page, which gameplay legitimately overwrites.
class PsyCrossCampaignSaveRenderer final {
public:
  PsyCrossCampaignSaveRenderer(const game::MissionPackage &mission,
                               KeyboardMouseBindings input);
  ~PsyCrossCampaignSaveRenderer();

  PsyCrossCampaignSaveRenderer(const PsyCrossCampaignSaveRenderer &) = delete;
  PsyCrossCampaignSaveRenderer &
  operator=(const PsyCrossCampaignSaveRenderer &) = delete;

  void draw(const game::CampaignSaveMenu &menu,
            const game::TitleSaveSlots &slots);
  void drawLoadSlots(const game::TitleSaveSlots &slots, std::size_t selection);
  void drawDifficultySelection(const game::TitleMenu &menu);
  void drawAgentModeWarning();
  void setInputPromptBindings(InputPromptBindings bindings);

private:
  struct State;
  std::unique_ptr<State> state_;
};

class PsyCrossSceneViewer final {
public:
  PsyCrossSceneViewer(
      KeyboardMouseBindings input, game::RetailCheatState &cheats,
      game::CampaignDifficulty difficulty,
      ControllerButtonBindings controller_bindings = {},
      bool controller_vibration = true,
      ControllerSettingsCommitCallback controller_settings_commit = {},
      bool mission_skyboxes = true) noexcept
      : input_(input), cheats_(cheats), difficulty_(difficulty),
        controller_bindings_(controller_bindings),
        controller_vibration_(controller_vibration),
        controller_settings_commit_(controller_settings_commit),
        mission_skyboxes_(mission_skyboxes) {}

  [[nodiscard]] SceneViewerResult
  run(const game::MissionPackage &mission, PADRAW &pad,
      std::uint16_t previous_buttons, const std::filesystem::path &cue_path,
      std::uint32_t maximum_unlocked_mission,
      std::unique_ptr<game::GameplaySession> preloaded_gameplay = {},
      std::unique_ptr<PsyCrossAudioOutput> preloaded_audio = {},
      SceneViewerRunOptions options = {});

private:
  KeyboardMouseBindings input_;
  game::RetailCheatState &cheats_;
  game::CampaignDifficulty difficulty_{game::CampaignDifficulty::original};
  ControllerButtonBindings controller_bindings_;
  bool controller_vibration_{true};
  ControllerSettingsCommitCallback controller_settings_commit_;
  bool mission_skyboxes_{true};
  game::PauseSettings pause_settings_;
  bool pause_settings_initialized_{};
};

} // namespace sf::platform::detail
