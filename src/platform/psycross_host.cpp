#include "sf/platform/host.hpp"

#include "psycross_audio_output.hpp"
#include "psycross_mission_start.hpp"
#include "psycross_movie_player.hpp"
#include "psycross_scene_viewer.hpp"
#include "psycross_vram.hpp"
#include "volumetric_atlas_texture.hpp"
#include "psycross_video_mode.hpp"
#include "psycross_window_mode.hpp"

#include "sf/core/error.hpp"
#include "sf/game/campaign.hpp"
#include "sf/game/game_disc.hpp"
#include "sf/game/gameplay.hpp"
#include "sf/game/legacy_presentation_bridge.hpp"
#include "sf/game/mission.hpp"
#include "sf/game/retail_cheats.hpp"
#include "sf/game/title.hpp"

#include <PsyX/PsyX_globals.h>
#include <PsyX/PsyX_public.h>
#include <PsyX/PsyX_render.h>
#include <SDL.h>
#include <psx/libetc.h>
#include <psx/libgpu.h>
#include <psx/libgte.h>
#include <psx/libpad.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <limits>
#include <optional>
#include <span>
#include <utility>
#include <vector>

#if defined(__APPLE__)
#include <pthread.h>
#endif

namespace sf::platform {
namespace {

constexpr std::size_t maximum_smoke_readback_pixels = 16U * 1024U * 1024U;
constexpr std::uint64_t fnv1a_offset_basis = 14695981039346656037ULL;
constexpr std::uint64_t fnv1a_prime = 1099511628211ULL;

[[nodiscard]] std::uint32_t drainFirstGlError() noexcept {
  auto first = std::uint32_t{};
  for (auto index = 0U; index < 64U; ++index) {
    const auto error = glGetError();
    if (error == GL_NO_ERROR) {
      break;
    }
    if (first == 0U) {
      first = static_cast<std::uint32_t>(error);
    }
  }
  return first;
}

struct ScopedGlReadbackState final {
  GLint draw_framebuffer{};
  GLint read_framebuffer{};
  GLint renderbuffer{};
  GLint pixel_pack_buffer{};
  GLint pack_alignment{4};
  bool restored{};

  void restore() noexcept {
    if (restored) {
      return;
    }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,
                      static_cast<GLuint>(draw_framebuffer));
    glBindFramebuffer(GL_READ_FRAMEBUFFER,
                      static_cast<GLuint>(read_framebuffer));
    glBindRenderbuffer(GL_RENDERBUFFER, static_cast<GLuint>(renderbuffer));
    glBindBuffer(GL_PIXEL_PACK_BUFFER,
                 static_cast<GLuint>(pixel_pack_buffer));
    glPixelStorei(GL_PACK_ALIGNMENT, pack_alignment);
    restored = true;
  }

  ~ScopedGlReadbackState() { restore(); }
};

template <typename SmokeEvidenceResult>
void normalizeSubmissionEvidence(
    const detail::SceneFrameSubmission &submission,
    SmokeEvidenceResult &result) noexcept {
  result.submitted_primitives = submission.submitted;
  result.rejected_primitives = submission.rejected;
  if (submission.submitted == 0U) {
    result.minimum_depth = 0;
    result.maximum_depth = 0;
    result.minimum_x = 0;
    result.maximum_x = 0;
    result.minimum_y = 0;
    result.maximum_y = 0;
    return;
  }
  result.minimum_depth = submission.minimum_depth;
  result.maximum_depth = submission.maximum_depth;
  result.minimum_x = submission.minimum_x;
  result.maximum_x = submission.maximum_x;
  result.minimum_y = submission.minimum_y;
  result.maximum_y = submission.maximum_y;
}

template <typename SmokeEvidenceResult>
void captureGuestFrameEvidence(const detail::SceneFrameSubmission &submission,
                               SmokeEvidenceResult &result) {
  result.observer_called = true;
  normalizeSubmissionEvidence(submission, result);
  result.renderer_gl_error = drainFirstGlError();

  ScopedGlReadbackState saved;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &saved.draw_framebuffer);
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &saved.read_framebuffer);
  glGetIntegerv(GL_RENDERBUFFER_BINDING, &saved.renderbuffer);
  glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &saved.pixel_pack_buffer);
  glGetIntegerv(GL_PACK_ALIGNMENT, &saved.pack_alignment);
  const auto binding_query_error = drainFirstGlError();
  if (result.renderer_gl_error == 0U) {
    result.renderer_gl_error = binding_query_error;
  }

  result.draw_framebuffer =
      static_cast<std::uint32_t>(saved.draw_framebuffer);
  // Read exactly the native target which received the production draw, then
  // restore the caller's independent read binding before PsyX_EndScene.
  glBindFramebuffer(GL_READ_FRAMEBUFFER,
                    static_cast<GLuint>(saved.draw_framebuffer));
  GLint read_framebuffer{};
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
  result.read_framebuffer = static_cast<std::uint32_t>(read_framebuffer);
  result.framebuffer_status =
      static_cast<std::uint32_t>(glCheckFramebufferStatus(GL_FRAMEBUFFER));

  std::array<GLint, 4U> viewport{};
  glGetIntegerv(GL_VIEWPORT, viewport.data());
  result.viewport_x = viewport[0];
  result.viewport_y = viewport[1];
  result.viewport_width = viewport[2];
  result.viewport_height = viewport[3];
  const auto framebuffer_query_error = drainFirstGlError();
  if (result.renderer_gl_error == 0U) {
    result.renderer_gl_error = framebuffer_query_error;
  }

  if (result.framebuffer_status != GL_FRAMEBUFFER_COMPLETE ||
      result.viewport_width <= 0 || result.viewport_height <= 0 ||
      result.viewport_x < 0 || result.viewport_y < 0) {
    saved.restore();
    const auto restore_error = drainFirstGlError();
    if (result.readback_gl_error == 0U) {
      result.readback_gl_error = restore_error;
    }
    return;
  }

  const auto width = static_cast<std::size_t>(result.viewport_width);
  const auto height = static_cast<std::size_t>(result.viewport_height);
  if (height > maximum_smoke_readback_pixels / width) {
    saved.restore();
    return;
  }
  const auto pixel_count = width * height;
  if (pixel_count == 0U || pixel_count > maximum_smoke_readback_pixels) {
    saved.restore();
    return;
  }

  std::vector<std::uint8_t> pixels(pixel_count * 4U);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0U);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glFinish();
  glReadPixels(result.viewport_x, result.viewport_y, result.viewport_width,
               result.viewport_height, GL_RGBA, GL_UNSIGNED_BYTE,
               pixels.data());
  result.readback_gl_error = drainFirstGlError();
  saved.restore();
  const auto restore_error = drainFirstGlError();
  if (result.readback_gl_error == 0U) {
    result.readback_gl_error = restore_error;
  }
  if (result.readback_gl_error != 0U) {
    return;
  }

  result.pixel_count = pixel_count;
  std::copy_n(pixels.begin(), result.lower_left_pixel.size(),
              result.lower_left_pixel.begin());
  const auto center_offset =
      ((height / 2U) * width + (width / 2U)) * 4U;
  std::copy_n(pixels.begin() + static_cast<std::ptrdiff_t>(center_offset),
              result.center_pixel.size(), result.center_pixel.begin());

  std::array<std::uint64_t, 64U> rgb_buckets{};
  result.pixel_hash = fnv1a_offset_basis;
  for (auto byte : pixels) {
    result.pixel_hash ^= byte;
    result.pixel_hash *= fnv1a_prime;
  }
  for (auto offset = std::size_t{}; offset < pixels.size(); offset += 4U) {
    const auto red = pixels[offset];
    const auto green = pixels[offset + 1U];
    const auto blue = pixels[offset + 2U];
    const auto alpha = pixels[offset + 3U];
    if (alpha >= 240U) {
      ++result.opaque_pixel_count;
    }
    if (red != result.lower_left_pixel[0] ||
        green != result.lower_left_pixel[1] ||
        blue != result.lower_left_pixel[2]) {
      ++result.nonuniform_pixel_count;
    }
    const auto bucket = static_cast<std::uint16_t>(
        (static_cast<std::uint16_t>(red >> 4U) << 8U) |
        (static_cast<std::uint16_t>(green >> 4U) << 4U) |
        static_cast<std::uint16_t>(blue >> 4U));
    auto &bucket_word = rgb_buckets[bucket / 64U];
    const auto bucket_bit = std::uint64_t{1U} << (bucket % 64U);
    if ((bucket_word & bucket_bit) == 0U) {
      bucket_word |= bucket_bit;
      ++result.unique_rgb_buckets;
    }
    const auto luminance = static_cast<std::uint8_t>(
        (54U * red + 183U * green + 19U * blue) >> 8U);
    result.minimum_luminance =
        std::min(result.minimum_luminance, luminance);
    result.maximum_luminance =
        std::max(result.maximum_luminance, luminance);
  }
}

[[nodiscard]] bool hasVisibleGuestSource(
    const game::GameplaySession &gameplay,
    const game::LegacyPresentationFrame &frame) noexcept {
  const auto &renderer = frame.renderer->state;
  return !gameplay.presentationModels().empty() || renderer.scrim.visible ||
         renderer.player.resident || !renderer.guest_sprites.empty() ||
         !renderer.guest_lines.empty() ||
         !renderer.guest_raw_packets.empty();
}

detail::StandaloneMovieSkipPolicy
endingMovieSkipPolicy(const game::MissionDefinition &definition) noexcept {
  const auto catalog = game::missionCatalog();
  if (!catalog.empty() && definition.index == catalog.back().index) {
    // EOL/SILO.STR contains the credits and the post-credits scene.  It is a
    // single retail stream, so allowing a carried confirm/cancel edge from the
    // save menu to skip it loses the entire campaign ending.
    return detail::StandaloneMovieSkipPolicy::prevent;
  }
  return detail::StandaloneMovieSkipPolicy::allow;
}

void configureGraphics(const GraphicsSettings &settings) noexcept {
  // SMAA and MSAA are complete scene antialiasing alternatives. Keeping them
  // exclusive avoids paying twice and gives SMAA an ordinary single-sample
  // depth texture for geometry-aware edge detection.
  g_cfg_msaaSamples = settings.smaa ? 0 : settings.msaa_samples;
  g_cfg_bilinearFiltering = settings.bilinear_filtering ? 1 : 0;
  g_cfg_trilinearFiltering = settings.trilinear_filtering ? 1 : 0;
  g_cfg_anisotropicFiltering = settings.anisotropic_filtering ? 1 : 0;
  g_cfg_smaa = settings.smaa ? 1 : 0;
  g_cfg_volumetricEffects = settings.volumetric_effects ? 1 : 0;
  g_cfg_aspectMode = settings.aspect_ratio == AspectRatioMode::adaptive
                         ? PSYX_ASPECT_ADAPTIVE
                         : PSYX_ASPECT_ORIGINAL_4_3;
  g_cfg_renderWidth = std::max(settings.width, 1);
  g_cfg_renderHeight = std::max(settings.height, 1);
  g_cfg_swapInterval = settings.vsync ? 1 : 0;
  // Presentation is native: no game code samples the displayed framebuffer
  // through PSX VRAM, and the guest simulation has its own deterministic
  // 20 Hz clock. Avoid the legacy readback and busy VBlank compatibility
  // paths, both of which otherwise steal time from display-refresh pacing.
  g_cfg_framebufferFeedback = 0;
  g_cfg_vblankThread = 0;
}

void configureControllerProtocol(ControllerProtocol protocol) noexcept {
  const auto set = [](const char *name, bool enabled) {
    static_cast<void>(
        SDL_SetHintWithPriority(name, enabled ? "1" : "0", SDL_HINT_OVERRIDE));
  };

  // Fix the Windows joystick driver set before SDL initializes it. Forced
  // modes disable competing drivers so one physical pad is opened once.
  const auto automatic = protocol == ControllerProtocol::automatic;
  set(SDL_HINT_XINPUT_ENABLED,
      automatic || protocol == ControllerProtocol::xinput);
  set(SDL_HINT_DIRECTINPUT_ENABLED,
      automatic || protocol == ControllerProtocol::direct_input);
  set(SDL_HINT_JOYSTICK_RAWINPUT,
      automatic || protocol == ControllerProtocol::raw_input);
  set(SDL_HINT_JOYSTICK_RAWINPUT_CORRELATE_XINPUT, true);
  set(SDL_HINT_JOYSTICK_WGI, automatic);
  set(SDL_HINT_JOYSTICK_HIDAPI, automatic);
  set(SDL_HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, true);
  set(SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, true);
}

void configurePresentation(const GraphicsSettings &settings) noexcept {
  // SDL's high-resolution timer and GL context both exist only after
  // PsyX_Initialise. Apply the two independent presentation controls here:
  // swap interval removes tearing, while the software cap controls cadence.
  PsyX_EnableSwapInterval(settings.vsync ? 1 : 0);
  PsyX_SetSwapInterval(1);
  PsyX_SetFrameLimit(static_cast<int>(settings.frame_limit));
  if (settings.volumetric_effects) {
    using namespace detail::volumetric_atlas_texture;
    static_assert(rgba.size() == static_cast<std::size_t>(width) * height * 4U);
    if (GR_UploadVolumetricDensityAtlas(
            static_cast<int>(width), static_cast<int>(height), rgba.data()) ==
        0) {
      // The renderer keeps its procedural volume path, and ultimately the
      // exact retail sprite fallback, if the authored atlas cannot upload.
      PsyX_Log_Warning(
          "Volumetric density atlas is unavailable; using procedural shapes\n");
    }
  }
}

void configureInput() {
  g_cfg_keyboardMapping.kc_dpad_up =
      PsyX_LookupKeyboardMapping("W", g_cfg_keyboardMapping.kc_dpad_up);
  g_cfg_keyboardMapping.kc_dpad_down =
      PsyX_LookupKeyboardMapping("S", g_cfg_keyboardMapping.kc_dpad_down);
  g_cfg_keyboardMapping.kc_dpad_left =
      PsyX_LookupKeyboardMapping("A", g_cfg_keyboardMapping.kc_dpad_left);
  g_cfg_keyboardMapping.kc_dpad_right =
      PsyX_LookupKeyboardMapping("D", g_cfg_keyboardMapping.kc_dpad_right);
  // PC actions are sampled directly by the player-input adapter. Keep them
  // out of PsyCross's merged virtual pad so Left Shift cannot turn a physical
  // R1 target-lock into the PC run action and Space cannot become Select.
  g_cfg_keyboardMapping.kc_r1 =
      PsyX_LookupKeyboardMapping("NONE", g_cfg_keyboardMapping.kc_r1);
  g_cfg_keyboardMapping.kc_l1 =
      PsyX_LookupKeyboardMapping("NONE", g_cfg_keyboardMapping.kc_l1);
  g_cfg_keyboardMapping.kc_select =
      PsyX_LookupKeyboardMapping("NONE", g_cfg_keyboardMapping.kc_select);
}

class PsyCrossHost final : public Host {
public:
  PsyCrossHost(std::string title, GraphicsSettings graphics)
      : title_(title.begin(), title.end()), graphics_(graphics) {
    title_.push_back('\0');
  }

  void run() override {
    configureGraphics(graphics_);
    configureControllerProtocol(graphics_.controller_protocol);
    PsyX_Initialise(title_.data(), graphics_.width, graphics_.height, 0);
    configurePresentation(graphics_);
    [[maybe_unused]] detail::PsyCrossWindowMode window_mode{
        graphics_.fullscreen};
    configureInput();
    detail::configurePsyCrossVideoMode(detail::gameplay_video_mode, true);
    for (;;) {
      if (PsyX_BeginScene() != 0) {
        PsyX_EndScene();
      }
    }
  }

private:
  std::vector<char> title_;
  GraphicsSettings graphics_;
};

void uploadTitleNoticeFont() {
  // Keep PsyCross's debug font clear of the title TIMs at x=896..950 and the
  // movie upload rectangle at x=0..319, y=256..495.
  FntLoad(960, 256);
}

void configureTitleNotice() {
  uploadTitleNoticeFont();
  static_cast<void>(FntOpen(54, 70, 252, 154, 2, 256));
}

game::TitleSaveSlots
loadTitleSaveSlots(const std::filesystem::path &path) noexcept {
  const auto loaded = game::loadTitleSaveSlotsFile(path);
  if (loaded.status == game::TitleSaveLoadStatus::invalid) {
    PsyX_Log_Error("Ignoring invalid or unreadable title save file\n");
  } else if (loaded.status == game::TitleSaveLoadStatus::recovered) {
    PsyX_Log_Info("Recovered title save from the last complete backup\n");
  }
  return loaded.slots;
}

bool storeTitleSaveSlots(const std::filesystem::path &path,
                         const game::TitleSaveSlots &slots) noexcept {
  const auto stored = game::storeTitleSaveSlotsFile(path, slots);
  if (!stored) {
    PsyX_Log_Error("Campaign progress could not be persisted\n");
  }
  return stored;
}

enum class SaveStoreDecision {
  stored,
  continue_without_saving,
  return_to_title,
};

std::uint16_t readHostButtons(const PADRAW &pad) noexcept {
  return static_cast<std::uint16_t>(pad.buttons[0]) |
         (static_cast<std::uint16_t>(pad.buttons[1]) << 8U);
}

KeyboardMouseActionSnapshot
sampleHostKeyboardMouseActions(const KeyboardMouseBindings &bindings) {
  int keyboard_count{};
  const auto *keyboard = SDL_GetKeyboardState(&keyboard_count);
  const auto keyboard_state =
      keyboard != nullptr && keyboard_count > 0
          ? std::span<const std::uint8_t>{keyboard, static_cast<std::size_t>(
                                                        keyboard_count)}
          : std::span<const std::uint8_t>{};
  const auto mouse_buttons = SDL_GetMouseState(nullptr, nullptr);
  return sampleKeyboardMouseActions(
      bindings, KeyboardMouseDeviceState{
                    .keyboard = keyboard_state,
                    .mouse_left = (mouse_buttons & SDL_BUTTON_LMASK) != 0U,
                    .mouse_right = (mouse_buttons & SDL_BUTTON_RMASK) != 0U,
                    .mouse_middle = (mouse_buttons & SDL_BUTTON_MMASK) != 0U,
                    .mouse_x1 = (mouse_buttons & SDL_BUTTON_X1MASK) != 0U,
                    .mouse_x2 = (mouse_buttons & SDL_BUTTON_X2MASK) != 0U,
                    .mouse_wheel_delta = detail::consumePsyCrossMouseWheel(),
                });
}

SaveStoreDecision
storeTitleSaveSlotsWithRecovery(const std::filesystem::path &path,
                                const game::TitleSaveSlots &slots, PADRAW &pad,
                                std::uint16_t &previous_buttons,
                                const KeyboardMouseBindings &bindings) {
  if (storeTitleSaveSlots(path, slots)) {
    return SaveStoreDecision::stored;
  }

  configureTitleNotice();
  constexpr std::uint16_t retry_buttons = 0x4000U | 0x08U;
  constexpr std::uint16_t continue_buttons = 0x8000U;
  constexpr std::uint16_t title_buttons = 0x2000U | 0x01U;
  const auto input_name = [&](KeyboardMouseAction action) {
    return std::string{keyboardMouseInputName(bindings[action])};
  };
  const auto notice =
      "       SAVE FAILED\n\n  " + input_name(KeyboardMouseAction::interact) +
      "  Retry\n  " + input_name(KeyboardMouseAction::fire) +
      "  Continue without saving\n  " + input_name(KeyboardMouseAction::pause) +
      "  Return to title\n\n"
      "Campaign progress remains active.";
  auto keyboard_initialized = false;
  auto interact_was_down = false;
  auto fire_was_down = false;
  auto pause_was_down = false;
  for (;;) {
    PsyX_UpdateInput();
    const auto buttons = readHostButtons(pad);
    const auto pressed =
        static_cast<std::uint16_t>(~buttons & previous_buttons);
    previous_buttons = buttons;
    const auto actions = sampleHostKeyboardMouseActions(bindings);
    const auto interact_down = actions[KeyboardMouseAction::interact];
    const auto fire_down = actions[KeyboardMouseAction::fire];
    const auto pause_down = actions[KeyboardMouseAction::pause];
    const auto interact_pressed =
        keyboard_initialized && interact_down && !interact_was_down;
    const auto fire_pressed =
        keyboard_initialized && fire_down && !fire_was_down;
    const auto pause_pressed =
        keyboard_initialized && pause_down && !pause_was_down;
    keyboard_initialized = true;
    interact_was_down = interact_down;
    fire_was_down = fire_down;
    pause_was_down = pause_down;

    if ((pressed & title_buttons) != 0U || pause_pressed) {
      return SaveStoreDecision::return_to_title;
    }
    if ((pressed & continue_buttons) != 0U || fire_pressed) {
      PsyX_Log_Info("Continuing campaign without durable save progress\n");
      return SaveStoreDecision::continue_without_saving;
    }
    if (((pressed & retry_buttons) != 0U || interact_pressed) &&
        storeTitleSaveSlots(path, slots)) {
      return SaveStoreDecision::stored;
    }

    if (PsyX_BeginScene() != 0) {
      char format[] = "%s";
      static_cast<void>(FntPrint(format, notice.c_str()));
      static_cast<void>(FntFlush());
      PsyX_EndScene();
    }
  }
}

ControllerMenuSample
controllerMenuSample(const PsyXControllerSnapshot &snapshot) noexcept;
ControllerMenuSample updateTitleInputPromptBindings(
    detail::PsyCrossCampaignSaveRenderer &renderer,
    const KeyboardMouseBindings &keyboard_bindings,
    const KeyboardMouseActionSnapshot &keyboard_actions,
    InputPromptBindings &active_bindings, int &previous_controller_instance);

game::CampaignSaveResult runCampaignSaveMenu(
    const game::MissionPackage &mission, const game::TitleSaveSlots &slots,
    PADRAW &pad, std::uint16_t &previous_buttons,
    detail::PsyCrossUiAudio &ui_audio, const KeyboardMouseBindings &bindings) {
  // Gameplay already owns the correct 384x240 presentation target. Reuse its
  // original font/ACD renderer instead of switching to the debug-font movie
  // target whose VRAM page has been overwritten by the mission renderer.
  detail::PsyCrossCampaignSaveRenderer renderer{mission, bindings};
  auto active_prompt_bindings = keyboardMouseInputPromptBindings(bindings);
  auto previous_controller_instance = -1;

  PsyX_Log_Info("Campaign save UI entered\n");
  game::CampaignSaveMenu menu;
  ControllerMenuNavigator analog_navigation;
  auto first_frame_presented = false;
  constexpr std::uint16_t previous_buttons_mask = 0x80U | 0x10U;
  constexpr std::uint16_t next_buttons_mask = 0x20U | 0x40U;
  constexpr std::uint16_t confirm_buttons_mask = 0x4000U | 0x8000U | 0x08U;
  constexpr std::uint16_t cancel_buttons_mask = 0x2000U | 0x01U;
  auto keyboard_initialized = false;
  auto interact_was_down = false;
  auto pause_was_down = false;
  for (;;) {
    PsyX_UpdateInput();
    ui_audio.update();
    const auto buttons = readHostButtons(pad);
    const auto pressed =
        static_cast<std::uint16_t>(~buttons & previous_buttons);
    previous_buttons = buttons;
    const auto actions = sampleHostKeyboardMouseActions(bindings);
    const auto interact_down = actions[KeyboardMouseAction::interact];
    const auto pause_down = actions[KeyboardMouseAction::pause];
    const auto interact_pressed =
        keyboard_initialized && interact_down && !interact_was_down;
    const auto pause_pressed =
        keyboard_initialized && pause_down && !pause_was_down;
    keyboard_initialized = true;
    interact_was_down = interact_down;
    pause_was_down = pause_down;
    const auto menu_sample = updateTitleInputPromptBindings(
        renderer, bindings, actions, active_prompt_bindings,
        previous_controller_instance);
    const auto analog = analog_navigation.update(menu_sample);
    const game::CampaignSaveInput input{
        (pressed & previous_buttons_mask) != 0U || analog.previous,
        (pressed & next_buttons_mask) != 0U || analog.next,
        (pressed & confirm_buttons_mask) != 0U || interact_pressed,
        (pressed & cancel_buttons_mask) != 0U || pause_pressed,
    };
    const auto previous_phase = menu.phase();
    const auto previous_save_selection = menu.saveSelected();
    const auto previous_overwrite_selection = menu.overwriteSelected();
    const auto previous_slot = menu.slotSelection();
    const auto result = menu.update(input, slots);
    if (input.cancel) {
      ui_audio.play(detail::PsyCrossUiCue::cancel);
    } else if (input.confirm) {
      ui_audio.play(detail::PsyCrossUiCue::confirm);
    } else if (menu.phase() != previous_phase ||
               menu.saveSelected() != previous_save_selection ||
               menu.overwriteSelected() != previous_overwrite_selection ||
               menu.slotSelection() != previous_slot) {
      ui_audio.play(detail::PsyCrossUiCue::navigate);
    }
    if (result.decision != game::CampaignSaveDecision::none) {
      return result;
    }

    // Draw into either a fresh scene or the still-open implicit scene left by
    // the terminal guest packet. Ending that scene before covering it used to
    // swap the old, un-faded gameplay backbuffer to the window for one frame.
    // The ACD renderer starts with an opaque full-screen black tile, so it is
    // also the correct recovery path for an inherited scene.
    static_cast<void>(PsyX_BeginScene());
    renderer.draw(menu, slots);
    PsyX_EndScene();
    if (!first_frame_presented) {
      first_frame_presented = true;
      PsyX_Log_Info("Campaign save UI first frame presented\n");
    }
  }
}

ControllerMenuSample
controllerMenuSample(const PsyXControllerSnapshot &snapshot) noexcept {
  if (snapshot.connected == 0U) {
    return {};
  }
  // Menus must remain usable after either gameplay stick layout is selected.
  // Collapse both physical sticks to the strongest axis; the stateful menu
  // navigator below rejects center noise and emits one edge per gesture.
  const auto axis =
      dominantControllerMenuAxis(snapshot.analog[0], snapshot.analog[1],
                                 snapshot.analog[2], snapshot.analog[3]);
  return ControllerMenuSample{.connected = true,
                              .instance_id = snapshot.instanceId,
                              .horizontal = 128U,
                              .vertical = axis};
}

ControllerMenuSample updateTitleInputPromptBindings(
    detail::PsyCrossCampaignSaveRenderer &renderer,
    const KeyboardMouseBindings &keyboard_bindings,
    const KeyboardMouseActionSnapshot &keyboard_actions,
    InputPromptBindings &active_bindings, int &previous_controller_instance) {
  PsyXControllerSnapshot snapshot{};
  static_cast<void>(PsyX_Pad_GetControllerSnapshot(0, &snapshot));
  const auto menu_sample = controllerMenuSample(snapshot);
  auto keyboard_mouse_activity = false;
  for (const auto held : keyboard_actions.held) {
    keyboard_mouse_activity = keyboard_mouse_activity || held;
  }
  const auto buttons = static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(snapshot.buttons[0]) |
      (static_cast<std::uint16_t>(snapshot.buttons[1]) << 8U));
  const auto controller_held = static_cast<std::uint16_t>(~buttons);
  constexpr int prompt_axis_deadzone = 56;
  const auto axis_offset = static_cast<int>(menu_sample.vertical) - 128;
  const auto controller_activity = controller_held != 0U ||
                                   axis_offset < -prompt_axis_deadzone ||
                                   axis_offset > prompt_axis_deadzone;
  const auto controller_identity_changed =
      menu_sample.connected &&
      snapshot.instanceId != previous_controller_instance;
  if (!menu_sample.connected || keyboard_mouse_activity) {
    active_bindings = keyboardMouseInputPromptBindings(keyboard_bindings);
  } else if (controller_activity || controller_identity_changed ||
             active_bindings.device == InputPromptDevice::controller) {
    active_bindings =
        detail::titleControllerInputPromptBindings(snapshot.family);
  }
  renderer.setInputPromptBindings(active_bindings);
  previous_controller_instance =
      menu_sample.connected ? snapshot.instanceId : -1;
  return menu_sample;
}

RECT16 blockRect(const assets::TimBlock &block) {
  const auto checked = [](std::uint16_t value) {
    if (value > static_cast<std::uint16_t>(std::numeric_limits<short>::max())) {
      throw core::Error{core::ErrorCode::unsupported,
                        "TIM VRAM coordinate exceeds PsyCross range"};
    }
    return static_cast<short>(value);
  };
  return RECT16{
      checked(block.x),
      checked(block.y),
      checked(block.width_words),
      checked(block.height),
  };
}

void uploadBlock(const assets::TimBlock &block) {
  auto rect = blockRect(block);
  auto packed = detail::packVramWords(block.words);
  LoadImage(&rect, packed.data());
}

int texturePageMode(assets::TimPixelMode mode) {
  switch (mode) {
  case assets::TimPixelMode::indexed4:
    return 0;
  case assets::TimPixelMode::indexed8:
    return 1;
  case assets::TimPixelMode::direct16:
    return 2;
  case assets::TimPixelMode::direct24:
    return 3;
  }
  return 2;
}

void uploadTitleAssets(const game::TitleAssets &assets) {
  for (const auto &sprite : assets.sprites()) {
    if (sprite.image.clut()) {
      uploadBlock(*sprite.image.clut());
    }
    uploadBlock(sprite.image.pixels());
  }
  DrawSync(0);
}

void drawTitleSprite(const game::TitleSprite &source, std::uint8_t brightness) {
  if (source.image.mode() != assets::TimPixelMode::indexed8 ||
      !source.image.clut()) {
    throw core::Error{core::ErrorCode::unsupported,
                      "Title menu sprites must use an 8-bit indexed TIM"};
  }

  const auto &pixels = source.image.pixels();
  const auto &clut = *source.image.clut();
  constexpr unsigned int texture_page_word_width = 64U;
  constexpr unsigned int texture_page_height = 256U;
  constexpr unsigned int indexed8_pixels_per_word = 2U;
  const auto u = static_cast<unsigned int>(pixels.x % texture_page_word_width) *
                 indexed8_pixels_per_word;
  const auto v = static_cast<unsigned int>(pixels.y % texture_page_height);
  const auto width = static_cast<unsigned int>(source.image.displayWidth());
  const auto height = static_cast<unsigned int>(source.image.displayHeight());
  if (u + width > 256U || v + height > 256U) {
    throw core::Error{core::ErrorCode::unsupported,
                      "Title menu TIM crosses its texture-page boundary"};
  }

  DR_TPAGE page{};
  // TITLE.OVL assigns ABR 1 (background + foreground) to all four sprites.
  // Title sprites are part of the visible 320x240 movie frame. Keep DFE
  // enabled so PsyCross composes them into the active display target, not its
  // VRAM-copy offscreen path.
  SetDrawTPage(&page, 1, 1, GetTPage(1, 1, pixels.x, pixels.y));
  DrawPrim(&page);

  // TITLE.OVL authored these positions for the regular 384x240 display, but
  // MOVIE.OVL presents TITLE.STR in a 320x240 target. A raw SPRT kept the
  // 384-wide coordinates and consequently pushed VIDEO.TIM through the right
  // edge of the 4:3 movie. Reproject the horizontal layout into the active
  // movie canvas; FT4 keeps the complete source image while independently
  // scaling its destination width.
  constexpr auto title_layout_width = 384U;
  constexpr auto title_movie_width = 320U;
  const auto scale_title_x = [](unsigned int value) {
    return (value * title_movie_width + title_layout_width / 2U) /
           title_layout_width;
  };
  const auto destination_x = scale_title_x(
      static_cast<unsigned int>(std::max<std::int16_t>(source.x, 0)));
  const auto destination_width = scale_title_x(width);
  const auto destination_y =
      static_cast<unsigned int>(std::max<std::int16_t>(source.y, 0));

  POLY_FT4 sprite{};
  setPolyFT4(&sprite);
  setSemiTrans(&sprite, 1);
  setRGB0(&sprite, brightness, brightness, brightness);
  sprite.tpage = GetTPage(1, 1, pixels.x, pixels.y);
  sprite.clut = GetClut(clut.x, clut.y);
  setXY4(&sprite, static_cast<float>(destination_x),
         static_cast<float>(destination_y),
         static_cast<float>(destination_x + destination_width),
         static_cast<float>(destination_y), static_cast<float>(destination_x),
         static_cast<float>(destination_y + height),
         static_cast<float>(destination_x + destination_width),
         static_cast<float>(destination_y + height));
  setUV4(&sprite, static_cast<u_char>(u), static_cast<u_char>(v),
         static_cast<u_char>(u + width), static_cast<u_char>(v),
         static_cast<u_char>(u), static_cast<u_char>(v + height),
         static_cast<u_char>(u + width), static_cast<u_char>(v + height));
  DrawPrim(&sprite);
}

class ControllerSettingsPersistence final {
public:
  ControllerSettingsPersistence(
      GraphicsSettings &graphics,
      const ControllerSettingsCommitCallback &callback) noexcept
      : graphics_(graphics), callback_(callback) {}

  [[nodiscard]] bool commit(const ControllerButtonBindings &bindings,
                            bool vibration) noexcept {
    graphics_.controller_bindings = bindings;
    graphics_.controller_vibration = vibration;
    return persistCurrent();
  }

  void retry() noexcept {
    if (!pending_) {
      return;
    }
    if (!persistCurrent()) {
      PsyX_Log_Warning("Controller settings persistence remains pending\n");
    }
  }

private:
  [[nodiscard]] bool persistCurrent() noexcept {
    if (!callback_) {
      pending_ = false;
      return true;
    }
    try {
      pending_ = !callback_(graphics_.controller_bindings,
                            graphics_.controller_vibration);
    } catch (...) {
      pending_ = true;
    }
    return !pending_;
  }

  GraphicsSettings &graphics_;
  const ControllerSettingsCommitCallback &callback_;
  bool pending_{};
};

class PsyCrossTitleHost final : public Host {
public:
  PsyCrossTitleHost(std::string title, game::TitleAssets assets,
                    game::TitleMovies movies,
                    game::MissionPackage initial_mission,
                    std::filesystem::path cue_path,
                    std::string supported_game_serial,
                    GraphicsSettings graphics, KeyboardMouseBindings input,
                    game::RetailCheatState cheats,
                    ControllerSettingsCommitCallback controller_settings_commit)
      : title_(title.begin(), title.end()), assets_(std::move(assets)),
        movies_(std::move(movies)),
        initial_mission_(std::move(initial_mission)),
        cue_path_(std::move(cue_path)),
        supported_game_serial_(std::move(supported_game_serial)),
        graphics_(graphics), input_(input), cheats_(cheats),
        controller_settings_commit_(std::move(controller_settings_commit)) {
    title_.push_back('\0');
  }

  void run() override {
    ControllerSettingsPersistence controller_settings_persistence{
        graphics_, controller_settings_commit_};
    configureGraphics(graphics_);
    configureControllerProtocol(graphics_.controller_protocol);
    PsyX_Initialise(title_.data(), graphics_.width, graphics_.height, 0);
    configurePresentation(graphics_);
    [[maybe_unused]] detail::PsyCrossWindowMode window_mode{
        graphics_.fullscreen};
    configureInput();
    detail::configurePsyCrossVideoMode(detail::gameplay_video_mode, true);

    uploadTitleAssets(assets_);
    configureTitleNotice();
    const auto save_location =
        game::defaultTitleSaveLocation(cue_path_, supported_game_serial_);
    const auto migration = game::migrateLegacyTitleSaveSlotsFile(save_location);
    if (migration == game::TitleSaveMigrationStatus::migrated) {
      PsyX_Log_Info("Migrated campaign save to the user-data directory\n");
    } else if (migration == game::TitleSaveMigrationStatus::failed) {
      PsyX_Log_Error("Legacy campaign save migration failed\n");
    }
    const auto &save_path = save_location.primary;
    menu_.setSaveSlots(loadTitleSaveSlots(save_path));
    PADRAW pad{};
    PadInitDirect(reinterpret_cast<unsigned char *>(&pad), nullptr);
    PadStartCom();

    std::uint16_t previous_buttons = 0xffffU;
    bool title_keyboard_initialized{};
    bool title_interact_was_down{};
    bool title_pause_was_down{};
    detail::PsyCrossUiAudio ui_audio{cue_path_};
    detail::PsyCrossMoviePlayer movie_player;
    auto active_title_prompt_bindings =
        keyboardMouseInputPromptBindings(input_);
    auto previous_title_controller_instance = -1;
    detail::PsyCrossCampaignSaveRenderer title_load_renderer{initial_mission_,
                                                             input_};
    const detail::MovieOverlayCallbacks overlay{
        [this, &pad, &ui_audio, &title_keyboard_initialized,
         &title_interact_was_down, &title_pause_was_down,
         &title_load_renderer, &active_title_prompt_bindings,
         &previous_title_controller_instance](
            std::uint16_t pressed, std::uint32_t movie_frame) {
          ui_audio.update();
          const auto actions = sampleHostKeyboardMouseActions(input_);
          const auto interact_down = actions[KeyboardMouseAction::interact];
          const auto pause_down = actions[KeyboardMouseAction::pause];
          const auto interact_pressed = title_keyboard_initialized &&
                                        interact_down &&
                                        !title_interact_was_down;
          const auto pause_pressed =
              title_keyboard_initialized && pause_down && !title_pause_was_down;
          title_keyboard_initialized = true;
          title_interact_was_down = interact_down;
          title_pause_was_down = pause_down;
          const auto menu_sample = updateTitleInputPromptBindings(
              title_load_renderer, input_, actions,
              active_title_prompt_bindings,
              previous_title_controller_instance);
          const auto analog = title_menu_navigation_.update(menu_sample);
          const bool root_title_menu =
              menu_.phase() == game::TitlePhase::searching ||
              menu_.phase() == game::TitlePhase::menu;
          bool controller_cancel =
              (pressed & (0x2000U | 0x01U)) != 0;
#if defined(__APPLE__)
          // On iOS, Circle and the DualSense Create/Share button map to the
          // PS1 Circle/Select bits. Exiting the process from the root title
          // looks like a hang when SpringBoard replaces the scene, so keep
          // those buttons as back only inside nested title screens.
          controller_cancel = controller_cancel && !root_title_menu;
#endif
          const game::TitleInput input{
              .previous = (pressed & (0x80U | 0x10U)) != 0 || analog.previous,
              .next = (pressed & (0x20U | 0x40U)) != 0 || analog.next,
              .confirm = (pressed & (0x4000U | 0x8000U | 0x08U)) != 0 ||
                         interact_pressed,
              .cancel = controller_cancel || pause_pressed,
              .confirm_down = ((~readHostButtons(pad)) &
                               (0x4000U | 0x8000U | 0x08U)) != 0U ||
                              interact_down,
          };
          const auto previous_selection = menu_.selection();
          const auto previous_phase = menu_.phase();
          const auto previous_slot = menu_.loadSlotSelection();
          const auto previous_difficulty = menu_.difficultySelection();
          const auto command = menu_.update(input, movie_frame);
          if ((previous_phase == game::TitlePhase::load_slots ||
               previous_phase == game::TitlePhase::select_difficulty ||
               previous_phase == game::TitlePhase::agent_warning) &&
              menu_.phase() == game::TitlePhase::menu) {
            // The retail font atlas shares VRAM pages with TITLE.HOG. Restore
            // the title sprites before returning from a font-backed picker.
            uploadTitleAssets(assets_);
          }
          if (input.cancel) {
            ui_audio.play(detail::PsyCrossUiCue::cancel);
          } else if (input.confirm && (command != game::TitleCommand::none ||
                                       menu_.phase() != previous_phase)) {
            ui_audio.play(detail::PsyCrossUiCue::confirm);
          } else if (menu_.selection() != previous_selection ||
                     menu_.loadSlotSelection() != previous_slot ||
                     menu_.difficultySelection() != previous_difficulty) {
            ui_audio.play(detail::PsyCrossUiCue::navigate);
          }
          if (command == game::TitleCommand::exit ||
              command == game::TitleCommand::new_game ||
              command == game::TitleCommand::load_game ||
              command == game::TitleCommand::training_video) {
            selected_command_ = command;
            PsyX_Log_Info("Title command accepted: %s\n",
                          game::titleCommandName(command).data());
            return false;
          }
          return true;
        },
        [this, &title_load_renderer] {
          if (menu_.phase() == game::TitlePhase::load_slots) {
            title_load_renderer.drawLoadSlots(menu_.saveSlots(),
                                              menu_.loadSlotSelection());
          } else if (menu_.phase() == game::TitlePhase::select_difficulty) {
            title_load_renderer.drawDifficultySelection(menu_);
          } else if (menu_.phase() == game::TitlePhase::agent_warning) {
            title_load_renderer.drawAgentModeWarning();
          } else {
            for (std::size_t index = 0; index < game::TitleMenu::visual_count;
                 ++index) {
              const auto visual = static_cast<game::TitleVisual>(index);
              const auto brightness = menu_.brightness(visual);
              if (brightness != 0) {
                drawTitleSprite(assets_.sprite(visual), brightness);
              }
            }
          }
        },
        [this]() -> const game::DiscMovie * {
          if (selected_command_ == game::TitleCommand::new_game &&
              !initial_mission_.openingMovie().path.empty()) {
            return &initial_mission_.openingMovie();
          }
          if (selected_command_ == game::TitleCommand::training_video) {
            return &movies_.trainingMovie();
          }
          return nullptr;
        },
    };
    auto play_startup_movies = true;
    for (;;) {
      selected_command_ = game::TitleCommand::none;
      // Baseline the first live title frame. A stick held through startup,
      // training video, or a return from gameplay must be released before it
      // can move the selection.
      title_menu_navigation_.reset();
      previous_buttons = movie_player.play(movies_, pad, previous_buttons,
                                           overlay, play_startup_movies);
      if (selected_command_ == game::TitleCommand::training_video) {
        menu_.completeSearch();
        play_startup_movies = false;
        continue;
      }
      play_startup_movies = false;

      if (selected_command_ != game::TitleCommand::new_game &&
          selected_command_ != game::TitleCommand::load_game) {
        break;
      }
      auto save_slots = menu_.saveSlots();
      const auto title_played_opening_movie =
          selected_command_ == game::TitleCommand::new_game &&
          !initial_mission_.openingMovie().path.empty();
      std::optional<game::CampaignProgress> campaign;
      auto campaign_carry = std::optional<game::CampaignCarryState>{};
      if (selected_command_ == game::TitleCommand::load_game) {
        campaign = game::CampaignProgress::resume(save_slots,
                                                  menu_.loadSlotSelection());
        if (!campaign) {
          PsyX_Log_Error("Load Game rejected invalid selected slot\n");
          uploadTitleAssets(assets_);
          configureTitleNotice();
          menu_.setSaveSlots(loadTitleSaveSlots(save_path));
          continue;
        }
        PsyX_Log_Info("Load Game: slot=%zu mission=%u\n",
                      *campaign->saveSlot() + 1U, campaign->missionIndex());
        campaign_carry = save_slots[*campaign->saveSlot()].carry;
      } else {
        campaign = game::CampaignProgress::startUnsaved(
            initial_mission_.definition().index, title_played_opening_movie,
            menu_.selectedDifficulty());
        if (!campaign) {
          PsyX_Log_Error("New Game rejected an invalid campaign cursor\n");
          uploadTitleAssets(assets_);
          configureTitleNotice();
          menu_.setSaveSlots(loadTitleSaveSlots(save_path));
          continue;
        }
        PsyX_Log_Info(
            "New Game FMV complete; opening unsaved mission %u "
            "on %s difficulty\n",
            campaign->missionIndex() + 1U,
            game::campaignDifficultyDisplayName(campaign->difficulty()).data());
      }
      controller_settings_persistence.retry();
      detail::PsyCrossMissionStart mission_start;
      const auto commit_controller_settings =
          [&controller_settings_persistence](
              const ControllerButtonBindings &bindings, bool vibration) {
            return controller_settings_persistence.commit(bindings, vibration);
          };
      detail::PsyCrossSceneViewer scene_viewer{input_,
                                               cheats_,
                                               campaign->difficulty(),
                                               graphics_.controller_bindings,
                                               graphics_.controller_vibration,
                                               commit_controller_settings,
                                               graphics_.mission_skyboxes};
      std::optional<game::MissionPackage> loaded_mission;
      auto exit_application = false;
      while (campaign->active()) {
        const auto mission_index = campaign->missionIndex();
        game::MissionPackage *mission{};
        if (mission_index == initial_mission_.definition().index) {
          mission = &initial_mission_;
        } else {
          auto disc = game::GameDisc::open(cue_path_);
          loaded_mission.emplace(
              game::MissionPackage::load(disc, mission_index));
          mission = &*loaded_mission;
        }
        if (campaign->pendingEndingMovieMission()) {
          PsyX_Log_Info("Recovering interrupted EOL for mission %u\n",
                        mission_index + 1U);
          if (!mission->endingMovie().path.empty()) {
            previous_buttons = movie_player.playStandalone(
                mission->endingMovie(), pad, previous_buttons,
                endingMovieSkipPolicy(mission->definition()));
          }
          auto candidate_campaign = *campaign;
          auto candidate_slots = save_slots;
          const auto advance =
              candidate_campaign.completeMission(candidate_slots);
          if (advance == game::CampaignAdvance::invalid) {
            PsyX_Log_Error("Pending EOL transition is inconsistent\n");
            break;
          }
          const auto store_decision = storeTitleSaveSlotsWithRecovery(
              save_path, candidate_slots, pad, previous_buttons, input_);
          if (store_decision == SaveStoreDecision::return_to_title) {
            break;
          }
          *campaign = candidate_campaign;
          save_slots = candidate_slots;
          campaign_carry = campaign->saveSlot()
                               ? save_slots[*campaign->saveSlot()].carry
                               : std::nullopt;
          if (advance == game::CampaignAdvance::campaign_complete) {
            PsyX_Log_Info("Campaign complete\n");
            break;
          }
          continue;
        }
        if (campaign->openingMovieRequired(mission->definition())) {
          previous_buttons = movie_player.playStandalone(
              mission->openingMovie(), pad, previous_buttons);
        }
        campaign->markOpeningMovieHandled();
        // Every campaign entry owns a mission-start loading boundary. DLFs
        // with authored directive text use it verbatim; continuation maps use
        // their catalog title instead of silently skipping the briefing UI.
        previous_buttons = mission_start.run(
            *mission, pad, previous_buttons, input_, campaign_carry,
            campaign->difficulty() == game::CampaignDifficulty::agent);

        const auto &definition = mission->definition();
        std::cout << "Starting mission " << (definition.index + 1U) << ": "
                  << definition.title << " [" << definition.resource_name
                  << "]\nMounted " << mission->archive().entries().size()
                  << " FOG files, " << mission->textureFileCount()
                  << " textures and " << mission->worldModelCount()
                  << " world models\n";
        const auto scene_result =
            scene_viewer.run(*mission, pad, previous_buttons, cue_path_,
                             campaign->maximumUnlockedMission(),
                             mission_start.takePreloadedGameplay(),
                             mission_start.takePreloadedAudio());
        controller_settings_persistence.retry();
        previous_buttons = scene_result.previous_buttons;
        if (scene_result.reason == detail::SceneExitReason::mission_selected &&
            scene_result.selected_mission) {
          const auto selected = *scene_result.selected_mission;
          if (!campaign->selectUnlockedMission(selected)) {
            // Reaching this branch requires the explicit all-missions cheat;
            // normal mission selection can never move beyond the high-water
            // mark of the loaded save.
            auto replacement = game::CampaignProgress::startUnsaved(
                selected, false, campaign->difficulty());
            if (!replacement) {
              PsyX_Log_Error("Pause mission selection rejected mission %u\n",
                             selected + 1U);
              break;
            }
            campaign = std::move(replacement);
          }
          campaign_carry.reset();
          loaded_mission.reset();
          PsyX_Log_Info("Pause mission selection: mission=%u\n", selected + 1U);
          continue;
        }
        if (scene_result.reason == detail::SceneExitReason::mission_complete) {
          const auto next_mission = mission_index + 1U;
          const auto carry_for_next =
              game::campaignMissionsShareCarry(mission_index, next_mission)
                  ? scene_result.carry
                  : std::nullopt;
          if (game::campaignMissionsShareCarry(mission_index, next_mission) &&
              !carry_for_next) {
            // A terminal overlay can retire its live inventory table before
            // the native host observes the EOL request. The scene viewer
            // normally supplies its last coherent snapshot; if even that is
            // unavailable, continuing with mission defaults is safer than
            // tearing down the entire campaign and returning to title.
            PsyX_Log_Warning(
                "Campaign transition has no coherent player carry; "
                "continuing with mission defaults\n");
          }
          const auto save_result = runCampaignSaveMenu(
              *mission, save_slots, pad, previous_buttons, ui_audio, input_);
          auto completion_is_saved = false;
          if (save_result.decision == game::CampaignSaveDecision::save &&
              save_result.slot) {
            auto staged_campaign = *campaign;
            auto staged_slots = save_slots;
            if (!staged_campaign.stageMissionCompletionInSlot(
                    staged_slots, *save_result.slot, carry_for_next)) {
              PsyX_Log_Error("Campaign save transaction rejected state\n");
              break;
            }
            // The selected slot remains on this mission with a pending EOL.
            // A shutdown during the following movie therefore resumes the
            // exact retail handoff instead of skipping it.
            const auto store_decision = storeTitleSaveSlotsWithRecovery(
                save_path, staged_slots, pad, previous_buttons, input_);
            if (store_decision == SaveStoreDecision::return_to_title) {
              break;
            }
            if (store_decision == SaveStoreDecision::stored) {
              *campaign = staged_campaign;
              save_slots = staged_slots;
              completion_is_saved = true;
            }
          }
          if (!mission->endingMovie().path.empty()) {
            previous_buttons = movie_player.playStandalone(
                mission->endingMovie(), pad, previous_buttons,
                endingMovieSkipPolicy(mission->definition()));
          }

          auto candidate_campaign = *campaign;
          auto candidate_slots = save_slots;
          const auto advance =
              completion_is_saved
                  ? candidate_campaign.completeMission(candidate_slots)
                  : candidate_campaign.completeMissionWithoutSaving();
          if (advance == game::CampaignAdvance::invalid) {
            PsyX_Log_Error("Campaign transition rejected inconsistent state\n");
            break;
          }
          if (completion_is_saved) {
            const auto store_decision = storeTitleSaveSlotsWithRecovery(
                save_path, candidate_slots, pad, previous_buttons, input_);
            if (store_decision == SaveStoreDecision::return_to_title) {
              break;
            }
          }
          *campaign = candidate_campaign;
          save_slots = candidate_slots;
          campaign_carry = advance == game::CampaignAdvance::next_mission
                               ? carry_for_next
                               : std::nullopt;
          if (advance == game::CampaignAdvance::campaign_complete) {
            PsyX_Log_Info("Campaign complete\n");
            break;
          }
          continue;
        }
        exit_application =
            scene_result.reason == detail::SceneExitReason::exit_application;
        break;
      }
      if (exit_application) {
        break;
      }
      uploadTitleAssets(assets_);
      configureTitleNotice();
      menu_.completeSearch();
      menu_.setSaveSlots(loadTitleSaveSlots(save_path));
    }
    PadStopCom();
  }

private:
  std::vector<char> title_;
  game::TitleAssets assets_;
  game::TitleMovies movies_;
  game::MissionPackage initial_mission_;
  std::filesystem::path cue_path_;
  std::string supported_game_serial_;
  game::TitleMenu menu_;
  game::TitleCommand selected_command_{game::TitleCommand::none};
  ControllerMenuNavigator title_menu_navigation_;
  GraphicsSettings graphics_;
  KeyboardMouseBindings input_;
  game::RetailCheatState cheats_;
  ControllerSettingsCommitCallback controller_settings_commit_;
};

class PsyCrossSceneHost final : public Host {
public:
  PsyCrossSceneHost(std::string title, game::MissionPackage mission,
                    std::filesystem::path cue_path, GraphicsSettings graphics,
                    KeyboardMouseBindings input, game::RetailCheatState cheats,
                    ControllerSettingsCommitCallback controller_settings_commit)
      : title_(title.begin(), title.end()), mission_(std::move(mission)),
        cue_path_(std::move(cue_path)), graphics_(graphics), input_(input),
        cheats_(cheats),
        controller_settings_commit_(std::move(controller_settings_commit)) {
    title_.push_back('\0');
  }

  void run() override {
    ControllerSettingsPersistence controller_settings_persistence{
        graphics_, controller_settings_commit_};
    configureGraphics(graphics_);
    configureControllerProtocol(graphics_.controller_protocol);
    PsyX_Initialise(title_.data(), graphics_.width, graphics_.height, 0);
    configurePresentation(graphics_);
    [[maybe_unused]] detail::PsyCrossWindowMode window_mode{
        graphics_.fullscreen};
    configureInput();
    detail::configurePsyCrossVideoMode(detail::gameplay_video_mode, true);

    PADRAW pad{};
    PadInitDirect(reinterpret_cast<unsigned char *>(&pad), nullptr);
    PadStartCom();
    detail::PsyCrossMoviePlayer movie_player;
    auto previous_buttons = std::uint16_t{0xffffU};
    if (!mission_.openingMovie().path.empty()) {
      previous_buttons = movie_player.playStandalone(mission_.openingMovie(),
                                                     pad, previous_buttons);
    }
    detail::PsyCrossMissionStart mission_start;
    previous_buttons =
        mission_start.run(mission_, pad, previous_buttons, input_);
    controller_settings_persistence.retry();
    const auto commit_controller_settings =
        [&controller_settings_persistence](
            const ControllerButtonBindings &bindings, bool vibration) {
          return controller_settings_persistence.commit(bindings, vibration);
        };
    detail::PsyCrossSceneViewer scene_viewer{input_,
                                             cheats_,
                                             game::CampaignDifficulty::original,
                                             graphics_.controller_bindings,
                                             graphics_.controller_vibration,
                                             commit_controller_settings,
                                             graphics_.mission_skyboxes};
    const auto result = scene_viewer.run(mission_, pad, previous_buttons,
                                         cue_path_, mission_.definition().index,
                                         mission_start.takePreloadedGameplay(),
                                         mission_start.takePreloadedAudio());
    controller_settings_persistence.retry();
    if (result.reason == detail::SceneExitReason::mission_complete &&
        !mission_.endingMovie().path.empty()) {
      static_cast<void>(movie_player.playStandalone(
          mission_.endingMovie(), pad, result.previous_buttons,
          endingMovieSkipPolicy(mission_.definition())));
    }
    PadStopCom();
  }

private:
  std::vector<char> title_;
  game::MissionPackage mission_;
  std::filesystem::path cue_path_;
  GraphicsSettings graphics_;
  KeyboardMouseBindings input_;
  game::RetailCheatState cheats_;
  ControllerSettingsCommitCallback controller_settings_commit_;
};

} // namespace

std::unique_ptr<Host> createPsyCrossHost(std::string title,
                                         GraphicsSettings graphics) {
  return std::make_unique<PsyCrossHost>(std::move(title), graphics);
}

std::unique_ptr<Host> createPsyCrossTitleHost(
    std::string title, game::TitleAssets assets, game::TitleMovies movies,
    game::MissionPackage initial_mission, std::filesystem::path cue_path,
    std::string supported_game_serial, GraphicsSettings graphics,
    KeyboardMouseBindings input, game::RetailCheatState cheats,
    ControllerSettingsCommitCallback controller_settings_commit) {
  return std::make_unique<PsyCrossTitleHost>(
      std::move(title), std::move(assets), std::move(movies),
      std::move(initial_mission), std::move(cue_path),
      std::move(supported_game_serial), graphics, input, cheats,
      std::move(controller_settings_commit));
}

std::unique_ptr<Host> createPsyCrossSceneHost(
    std::string title, game::MissionPackage mission,
    std::filesystem::path cue_path, GraphicsSettings graphics,
    KeyboardMouseBindings input, game::RetailCheatState cheats,
    ControllerSettingsCommitCallback controller_settings_commit) {
  return std::make_unique<PsyCrossSceneHost>(
      std::move(title), std::move(mission), std::move(cue_path), graphics,
      input, cheats, std::move(controller_settings_commit));
}

PsyCrossGuestFrameSmokeResult renderPsyCrossGuestFrameSmoke(
    const game::MissionPackage &mission,
    PsyCrossGuestFrameSmokeOptions options) {
  PsyCrossGuestFrameSmokeResult result;
  if (options.maximum_guest_updates == 0U ||
      options.maximum_guest_updates >
          PsyCrossGuestFrameSmokeOptions::hard_maximum_guest_updates) {
    result.status = PsyCrossGuestFrameSmokeStatus::invalid_options;
    return result;
  }
#if defined(__APPLE__)
  if (pthread_main_np() == 0) {
    result.status = PsyCrossGuestFrameSmokeStatus::wrong_thread;
    return result;
  }
#endif
  if (SDL_GL_GetCurrentWindow() == nullptr ||
      SDL_GL_GetCurrentContext() == nullptr) {
    result.status = PsyCrossGuestFrameSmokeStatus::missing_graphics_context;
    return result;
  }

  std::unique_ptr<game::GameplaySession> gameplay;
  try {
    gameplay = std::make_unique<game::GameplaySession>(mission);
  } catch (...) {
    result.status =
        PsyCrossGuestFrameSmokeStatus::initial_presentation_invalid;
    return result;
  }

  auto frame = gameplay->legacyPresentationFrame();
  if (!frame || gameplay->runtimeFaulted() ||
      !game::legacyPresentationFrameConsumable(*frame, 0U)) {
    result.status = gameplay->runtimeFaulted()
                        ? PsyCrossGuestFrameSmokeStatus::guest_runtime_fault
                        : PsyCrossGuestFrameSmokeStatus::
                              initial_presentation_invalid;
    return result;
  }

  auto previous_sequence = frame->sequence;
  for (auto update = std::uint32_t{1U};
       update <= options.maximum_guest_updates; ++update) {
    try {
      gameplay->update(game::GameplayInput{});
    } catch (...) {
      result.status = PsyCrossGuestFrameSmokeStatus::guest_runtime_fault;
      return result;
    }
    result.guest_updates = update;
    if (gameplay->runtimeFaulted()) {
      result.status = PsyCrossGuestFrameSmokeStatus::guest_runtime_fault;
      return result;
    }

    frame = gameplay->legacyPresentationFrame();
    if (!frame ||
        !game::legacyPresentationFrameConsumable(*frame, previous_sequence)) {
      result.status = PsyCrossGuestFrameSmokeStatus::presentation_invalid;
      return result;
    }
    previous_sequence = frame->sequence;
    result.presentation_sequence = frame->sequence;
    result.guest_frame = frame->guest_frame;
    result.fade_intensity = gameplay->mapFade();
    result.presentation_models = gameplay->presentationModels().size();
    result.active_objects = gameplay->activeObjects().size();
    result.coherent_presentation = true;
    result.visibility_threshold_met =
        result.fade_intensity <= options.maximum_fade_intensity &&
        hasVisibleGuestSource(*gameplay, *frame);
    if (result.visibility_threshold_met) {
      break;
    }
  }
  if (!result.visibility_threshold_met) {
    result.status = PsyCrossGuestFrameSmokeStatus::visibility_timeout;
    return result;
  }

  // Reset caller residue so the three reported GL errors belong only to this
  // bounded presentation, readback and present transaction.
  static_cast<void>(drainFirstGlError());
  detail::configurePsyCrossVideoMode(detail::gameplay_video_mode, true);

  PADRAW pad{};
  game::RetailCheatState cheats{};
  detail::PsyCrossSceneViewer scene_viewer{
      defaultKeyboardMouseBindings(), cheats,
      game::CampaignDifficulty::original, {}, false, {}, false};
  detail::SceneViewerResult viewer_result;
  try {
    viewer_result = scene_viewer.run(
        mission, pad, 0xffffU, std::filesystem::path{},
        mission.definition().index, std::move(gameplay), {},
        detail::SceneViewerRunOptions{
            .present_preloaded_frame_once = true,
            .expected_sequence = result.presentation_sequence,
            .expected_guest_frame = result.guest_frame,
            .before_end_scene = [&result](
                                    const detail::SceneFrameSubmission
                                        &submission) {
              captureGuestFrameEvidence(submission, result);
            },
        });
  } catch (...) {
    // Safe when no scene is active and necessary when drawing/readback threw
    // after DrawOTag opened the bounded presentation.
    PsyX_EndScene();
    result.present_gl_error = drainFirstGlError();
    result.status = PsyCrossGuestFrameSmokeStatus::renderer_rejected;
    return result;
  }
  result.present_gl_error = drainFirstGlError();

  if (viewer_result.reason !=
          detail::SceneExitReason::bounded_presentation_complete ||
      !result.observer_called || result.draw_framebuffer == 0U ||
      result.submitted_primitives == 0U) {
    result.status = PsyCrossGuestFrameSmokeStatus::renderer_rejected;
    return result;
  }
  if (result.framebuffer_status != GL_FRAMEBUFFER_COMPLETE) {
    result.status = PsyCrossGuestFrameSmokeStatus::framebuffer_incomplete;
    return result;
  }
  if (result.readback_gl_error != 0U || result.viewport_width <= 0 ||
      result.viewport_height <= 0 || result.pixel_count == 0U) {
    result.status = PsyCrossGuestFrameSmokeStatus::readback_failed;
    return result;
  }
  if (result.renderer_gl_error != 0U || result.present_gl_error != 0U) {
    result.status = PsyCrossGuestFrameSmokeStatus::renderer_rejected;
    return result;
  }
  if (result.opaque_pixel_count == 0U ||
      result.nonuniform_pixel_count == 0U || result.unique_rgb_buckets < 2U ||
      result.maximum_luminance <= result.minimum_luminance) {
    result.status = PsyCrossGuestFrameSmokeStatus::pixel_evidence_rejected;
    return result;
  }

  result.status = PsyCrossGuestFrameSmokeStatus::success;
  return result;
}

PsyCrossGuestLoopSmokeResult runPsyCrossGuestLoopSmoke(
    const game::MissionPackage &mission,
    PsyCrossGuestLoopSmokeOptions options) {
  PsyCrossGuestLoopSmokeResult result;
  if (options.presentation_count == 0U ||
      options.presentation_count >
          PsyCrossGuestLoopSmokeOptions::hard_maximum_presentations ||
      options.update_interval_seconds < (1.0 / 60.0) ||
      options.update_interval_seconds > 0.25 ||
      options.maximum_guest_updates == 0U ||
      options.maximum_guest_updates >
          PsyCrossGuestFrameSmokeOptions::hard_maximum_guest_updates) {
    result.status = PsyCrossGuestLoopSmokeStatus::invalid_options;
    return result;
  }
#if defined(__APPLE__)
  if (pthread_main_np() == 0) {
    result.status = PsyCrossGuestLoopSmokeStatus::wrong_thread;
    return result;
  }
#endif
  if (SDL_GL_GetCurrentWindow() == nullptr ||
      SDL_GL_GetCurrentContext() == nullptr) {
    result.status = PsyCrossGuestLoopSmokeStatus::missing_graphics_context;
    return result;
  }

  std::unique_ptr<game::GameplaySession> gameplay;
  try {
    gameplay = std::make_unique<game::GameplaySession>(mission);
  } catch (...) {
    result.status =
        PsyCrossGuestLoopSmokeStatus::initial_presentation_invalid;
    return result;
  }

  auto frame = gameplay->legacyPresentationFrame();
  if (!frame || gameplay->runtimeFaulted() ||
      !game::legacyPresentationFrameConsumable(*frame, 0U)) {
    result.status = gameplay->runtimeFaulted()
                        ? PsyCrossGuestLoopSmokeStatus::guest_runtime_fault
                        : PsyCrossGuestLoopSmokeStatus::
                              initial_presentation_invalid;
    return result;
  }

  auto previous_sequence = frame->sequence;
  for (auto update = std::uint32_t{1U};
       update <= options.maximum_guest_updates; ++update) {
    try {
      gameplay->update(game::GameplayInput{});
    } catch (...) {
      result.status = PsyCrossGuestLoopSmokeStatus::guest_runtime_fault;
      return result;
    }
    if (gameplay->runtimeFaulted()) {
      result.status = PsyCrossGuestLoopSmokeStatus::guest_runtime_fault;
      return result;
    }
    frame = gameplay->legacyPresentationFrame();
    if (!frame ||
        !game::legacyPresentationFrameConsumable(*frame, previous_sequence)) {
      result.status = PsyCrossGuestLoopSmokeStatus::presentation_invalid;
      return result;
    }
    previous_sequence = frame->sequence;
    result.visibility_threshold_met =
        gameplay->mapFade() <= options.maximum_fade_intensity &&
        hasVisibleGuestSource(*gameplay, *frame);
    if (result.visibility_threshold_met) {
      break;
    }
  }
  if (!result.visibility_threshold_met) {
    result.status = PsyCrossGuestLoopSmokeStatus::visibility_timeout;
    return result;
  }

  // Reset caller residue so the reported GL errors belong only to this loop.
  static_cast<void>(drainFirstGlError());
  detail::configurePsyCrossVideoMode(detail::gameplay_video_mode, true);

  PADRAW pad{};
  if (options.sample_controller) {
    // Register the smoke's pad buffer so PsyX fills it from the bound
    // physical controller, mirroring the scene host's setup.
    PadInitDirect(reinterpret_cast<unsigned char *>(&pad), nullptr);
    PadStartCom();
  }
  game::RetailCheatState cheats{};
  detail::PsyCrossSceneViewer scene_viewer{
      defaultKeyboardMouseBindings(), cheats,
      game::CampaignDifficulty::original, {}, false, {}, false};
  PsyCrossGuestFrameSmokeResult last_captured_evidence;
  auto sequence_monotonic = true;
  auto interval_sum_ms = 0.0;
  auto interval_count = 0U;
  auto previous_tracked_sequence = std::uint64_t{};
  auto background_started = std::chrono::steady_clock::time_point{};
  auto background_depth = 0U;
  detail::SceneViewerResult viewer_result;
  try {
    viewer_result = scene_viewer.run(
        mission, pad, 0xffffU, std::filesystem::path{},
        mission.definition().index, std::move(gameplay), {},
        detail::SceneViewerRunOptions{
            .continuous_guest_loop =
                detail::SceneViewerContinuousGuestLoopOptions{
                    .presentation_count = options.presentation_count,
                    .update_interval_seconds = options.update_interval_seconds,
                    .yield_to_host = options.yield_to_host,
                    .per_presentation =
                        [&](const detail::SceneLoopPresentation &loop_frame) {
                          ++result.presentations_completed;
                          result.guest_updates_completed += loop_frame.updates;
                          result.submitted_primitives +=
                              loop_frame.submission.submitted;
                          result.rejected_primitives +=
                              loop_frame.submission.rejected;
                          if (loop_frame.presentation_index == 1U) {
                            result.first_sequence =
                                loop_frame.submission.sequence;
                            result.first_guest_frame =
                                loop_frame.submission.guest_frame;
                            result.first_presentation_ms =
                                loop_frame.presentation_ms;
                          }
                          result.last_sequence = loop_frame.submission.sequence;
                          result.last_guest_frame =
                              loop_frame.submission.guest_frame;
                          result.last_presentation_ms =
                              loop_frame.presentation_ms;
                          result.minimum_depth =
                              loop_frame.submission.minimum_depth;
                          result.maximum_depth =
                              loop_frame.submission.maximum_depth;
                          result.minimum_x = loop_frame.submission.minimum_x;
                          result.maximum_x = loop_frame.submission.maximum_x;
                          result.minimum_y = loop_frame.submission.minimum_y;
                          result.maximum_y = loop_frame.submission.maximum_y;
                          if (result.presentations_completed > 1U &&
                              loop_frame.submission.sequence <=
                                  previous_tracked_sequence) {
                            sequence_monotonic = false;
                          }
                          previous_tracked_sequence =
                              loop_frame.submission.sequence;
                          // The first interval covers loop startup, so pacing
                          // statistics start with the second presentation.
                          if (loop_frame.presentation_index > 1U) {
                            interval_sum_ms += loop_frame.interval_ms;
                            if (interval_count == 0U) {
                              result.minimum_interval_ms =
                                  loop_frame.interval_ms;
                              result.maximum_interval_ms =
                                  loop_frame.interval_ms;
                            } else {
                              result.minimum_interval_ms =
                                  std::min(result.minimum_interval_ms,
                                           loop_frame.interval_ms);
                              result.maximum_interval_ms =
                                  std::max(result.maximum_interval_ms,
                                           loop_frame.interval_ms);
                            }
                            ++interval_count;
                          }
                          const auto error = drainFirstGlError();
                          if (result.renderer_gl_error == 0U) {
                            result.renderer_gl_error = error;
                          }
                          // Full framebuffer/pixel evidence only on the first
                          // and final presentations; the readback is too heavy
                          // to run at the paced 20 Hz rate.
                          if (loop_frame.presentation_index == 1U ||
                              loop_frame.presentation_index ==
                                  options.presentation_count) {
                            captureGuestFrameEvidence(loop_frame.submission,
                                                      last_captured_evidence);
                          }
                          if (options.per_presentation) {
                              options.per_presentation(
                                PsyCrossGuestLoopFrame{
                                    .presentation_index =
                                        loop_frame.presentation_index,
                                    .updates = loop_frame.updates,
                                    .sequence =
                                        loop_frame.submission.sequence,
                                    .guest_frame =
                                        loop_frame.submission.guest_frame,
                                    .submitted =
                                        loop_frame.submission.submitted,
                                    .rejected =
                                        loop_frame.submission.rejected,
                                    .presentation_ms =
                                        loop_frame.presentation_ms,
                                    .interval_ms = loop_frame.interval_ms,
                            });
                          }
                          return true;
                        },
                    .lifecycle_event =
                        [&](bool background, std::uint32_t index) {
                          if (background) {
                            ++result.background_events;
                            if (result.background_events == 1U) {
                              result.presentations_before_first_background =
                                  index;
                            }
                            if (background_depth == 0U) {
                              background_started =
                                  std::chrono::steady_clock::now();
                            }
                            ++background_depth;
                          } else {
                            ++result.foreground_events;
                            if (background_depth > 0U) {
                              --background_depth;
                              if (background_depth == 0U) {
                                result.total_background_ms +=
                                    std::chrono::duration<double,
                                                           std::milli>(
                                        std::chrono::steady_clock::now() -
                                        background_started)
                                        .count();
                              }
                            }
                          }
                          if (options.lifecycle_event) {
                            options.lifecycle_event(background, index);
                          }
                        },
                    .sample_controller = options.sample_controller,
                    .controller_observer =
                        [&options](
                            const detail::SceneControllerSample &sample) {
                          if (options.controller_observer) {
                            options.controller_observer(
                                PsyCrossGuestControllerSample{
                                    .connected = sample.connected,
                                    .instance_id = sample.instance_id,
                                    .controller_type = sample.controller_type,
                                    .name = sample.name,
                                    .buttons = sample.buttons,
                                    .analog = sample.analog,
                                    .move = sample.move,
                                    .turn = sample.turn,
                                    .strafe = sample.strafe,
                                    .aim = sample.aim,
                                    .fire = sample.fire,
                                    .interact = sample.interact,
                                    .player_x = sample.player_x,
                                    .player_y = sample.player_y,
                                    .player_z = sample.player_z,
                                    .player_yaw = sample.player_yaw,
                                });
                          }
                        },
                },
        });
  } catch (...) {
    // Safe when no scene is active and necessary when drawing threw after
    // DrawOTag opened a presentation.
    PsyX_EndScene();
    result.present_gl_error = drainFirstGlError();
    result.status = PsyCrossGuestLoopSmokeStatus::renderer_rejected;
    return result;
  }
  result.present_gl_error = drainFirstGlError();

  switch (viewer_result.reason) {
  case detail::SceneExitReason::continuous_loop_guest_fault:
    result.status = PsyCrossGuestLoopSmokeStatus::guest_runtime_fault;
    return result;
  case detail::SceneExitReason::continuous_loop_presentation_invalid:
    result.status = PsyCrossGuestLoopSmokeStatus::presentation_invalid;
    return result;
  case detail::SceneExitReason::continuous_loop_terminated:
    result.terminated_by_os = true;
    result.status = PsyCrossGuestLoopSmokeStatus::terminated_early;
    return result;
  default:
    break;
  }
  if (viewer_result.reason !=
          detail::SceneExitReason::continuous_loop_complete ||
      result.presentations_completed != options.presentation_count ||
      !sequence_monotonic) {
    result.status = PsyCrossGuestLoopSmokeStatus::renderer_rejected;
    return result;
  }
  result.mean_interval_ms =
      interval_count == 0U ? 0.0 : interval_sum_ms / interval_count;
  result.observer_called = last_captured_evidence.observer_called;
  result.renderer_gl_error = std::max(result.renderer_gl_error,
                                      last_captured_evidence.renderer_gl_error);
  result.readback_gl_error = last_captured_evidence.readback_gl_error;
  result.draw_framebuffer = last_captured_evidence.draw_framebuffer;
  result.read_framebuffer = last_captured_evidence.read_framebuffer;
  result.framebuffer_status = last_captured_evidence.framebuffer_status;
  result.viewport_x = last_captured_evidence.viewport_x;
  result.viewport_y = last_captured_evidence.viewport_y;
  result.viewport_width = last_captured_evidence.viewport_width;
  result.viewport_height = last_captured_evidence.viewport_height;
  result.pixel_count = last_captured_evidence.pixel_count;
  result.opaque_pixel_count = last_captured_evidence.opaque_pixel_count;
  result.nonuniform_pixel_count = last_captured_evidence.nonuniform_pixel_count;
  result.unique_rgb_buckets = last_captured_evidence.unique_rgb_buckets;
  result.minimum_luminance = last_captured_evidence.minimum_luminance;
  result.maximum_luminance = last_captured_evidence.maximum_luminance;
  result.lower_left_pixel = last_captured_evidence.lower_left_pixel;
  result.center_pixel = last_captured_evidence.center_pixel;
  result.pixel_hash = last_captured_evidence.pixel_hash;

  if (!result.observer_called) {
    result.status = PsyCrossGuestLoopSmokeStatus::renderer_rejected;
    return result;
  }
  if (result.framebuffer_status != GL_FRAMEBUFFER_COMPLETE) {
    result.status = PsyCrossGuestLoopSmokeStatus::framebuffer_incomplete;
    return result;
  }
  if (result.readback_gl_error != 0U || result.viewport_width <= 0 ||
      result.viewport_height <= 0 || result.pixel_count == 0U) {
    result.status = PsyCrossGuestLoopSmokeStatus::readback_failed;
    return result;
  }
  if (result.renderer_gl_error != 0U || result.present_gl_error != 0U) {
    result.status = PsyCrossGuestLoopSmokeStatus::renderer_rejected;
    return result;
  }
  if (result.opaque_pixel_count == 0U ||
      result.nonuniform_pixel_count == 0U || result.unique_rgb_buckets < 2U ||
      result.maximum_luminance <= result.minimum_luminance) {
    result.status = PsyCrossGuestLoopSmokeStatus::pixel_evidence_rejected;
    return result;
  }

  result.status = PsyCrossGuestLoopSmokeStatus::success;
  return result;
}

} // namespace sf::platform
