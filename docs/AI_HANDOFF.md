# AI handoff

## Updated

2026-08-15 21:23 CDT

## Workspace

`/Volumes/iPhone/PS1_Rrecomps/SF1` on branch `ios-port`; HEAD and
`origin/ios-port` are `84833b8`. The dedicated renderer smoke target and the
iOS-only PsyCross scene bridge are implemented, independently reviewed,
runtime-verified as a narrow renderer checkpoint, committed, and pushed.

## Current status

- Portable CUE/BIN folder discovery now validates one top-level CUE and its
  in-place companion BIN without copying media into the app sandbox.
- The iOS host presents a Files folder picker, retains a balanced security scope,
  saves an iOS minimal bookmark, coordinates preflight reads, and retains the CUE
  URL only while the directory lease is active.
- The iOS host discovers extended GameController devices and probes the intended
  PS1 mapping for MFi-compatible Xbox, DualShock 4, DualSense, and generic
  extended controllers. This native bridge is bootstrap diagnostics only; SDL2
  must own the final gameplay input path.
- The updated host builds, signs, installs, launches, and remains alive over Wi-Fi
  on the authorized iPhone 17 Pro Max. The visible UI reports no physical
  controller currently connected and offers `Choose Disc Folder`.
- The user has now selected the CUE/BIN folder on the physical phone after a USB
  transfer. The device UI reports the CUE ready in its external folder and that
  nothing was copied into the app. This is user-observed physical-device
  verification. After force-quitting/reopening, the device still reports the CUE
  ready, so security-scoped bookmark restoration is also user-verified. An agent
  then used `devicectl --terminate-existing` to relaunch the installed app and
  captured the same ready/no-copy state, independently verifying restoration.
- Pinned iOS SDL2/OpenAL Soft/FFmpeg packaging and PsyCross GLES3 compile/link
  portability checks pass and are pushed.
- A distinct ROM-free `sf_ios_renderer_smoke` bundle now owns an iOS 27
  `UIApplication`/`UIScene` lifecycle, attaches SDL2's UIKit window before GLES
  context creation, and presents a deterministic RGB triangle through
  `PsyX_BeginScene`/`PsyX_EndScene`.
- The renderer itself passes on the iOS 27 iPhone 17 Pro Max Simulator and on
  the USB-connected physical iPhone: GLES3 setup, deterministic pixel readback,
  framebuffer completeness, presentation, and frame-120 heartbeat all pass.
  The physical app used a distinct bundle ID, so it did not replace the
  bootstrap app or its saved external-disc bookmark.
- This checkpoint is not scene/orientation complete. A launch while the
  Simulator device is portrait produces a portrait scene with the landscape
  renderer rotated 90 degrees. Physical launch in landscape is visually
  correct. Production SDL2 scene ownership/orientation is blocking before game
  integration, not before this explicitly narrow renderer milestone.
- At the user's request, the retail CUE/BIN pair was copied from the external
  workspace into the currently installed Simulator app's `Documents/Ps1/`
  folder for interactive testing. It was not opened, inspected, or committed.

## Verified evidence

- Native macOS suite: 24/24 CTest tests passed, including synthetic disc-folder
  fixtures:
  `tmp/validation/2026-08-15-disc-controller-combined/macos-full-ctest.log`.
- Simulator Debug build and visual folder-picker/UI smoke:
  `tmp/validation/2026-08-15-external-disc/`.
- Simulator GameController synthetic mapping smoke: A/Cross + L2 + D-pad Up and
  quantized axes passed with mask `0x4110`:
  `tmp/validation/2026-08-15-gamecontroller/simulator-controller-fixed.log`.
- The requested Simulator `Documents/Ps1/` copy was repeated atomically; source
  and destination sizes match for both files. The app relaunched and visibly
  restored the CUE as ready:
  `tmp/validation/2026-08-15-simulator-retail-disc-copy/user-request-recopy/`.
- Signed device Release build:
  `tmp/validation/2026-08-15-disc-controller-device/ios-device-signed-build-rerun.log`.
- Signed product verification, install/launch/process/crash queries, and physical
  UI screenshot:
  `tmp/validation/2026-08-15-disc-controller-device/`.
  `iphone17promax-disc-controller-ui-landscape-readable.png` is the visually
  inspected orientation-correct copy. The app remained running and no matching
  device crash log was present.
- User-observed physical Files-folder smoke: after transferring the pair by USB
  and selecting its folder, the app reported the CUE ready and explicitly
  reported no app-local copy. It remained ready after force-quit/relaunch,
  verifying bookmark restoration at the UI level. No retail media was read or
  captured by an agent.
- Agent-captured physical bookmark-restoration smoke: `devicectl` terminated and
  relaunched the installed app, then captured the visible ready/no-copy state:
  `tmp/validation/2026-08-15-physical-disc-bookmark-user-confirmed/physical-cue-ready-agent-captured-readable.png`.
- Final pre-renderer checkpoint: macOS build passed with the documented
  warnings-as-errors exception, 24/24 CTest passed, iOS Simulator Debug and
  iphoneos Release shell builds passed, the complete pinned dependency matrix
  rebuilt and link-validated, and PsyCross force-link rechecks passed for both
  mobile platforms. Evidence:
  `tmp/validation/2026-08-15-pre-renderer-checkpoint/`.
- The initial renderer launch failure is preserved and diagnosed: SDL2 2.32.10's
  legacy `SDL_UIKitRunApp` path trapped in
  `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` on iOS 27.
  The user-provided crash report is
  `tmp/validation/2026-08-15-ios-renderer-smoke/SFRendererSmoke-Launch-Log.txt`.
- Simulator renderer evidence is indexed by
  `tmp/validation/2026-08-15-ios-renderer-smoke/README.md`: Release build,
  scene attachment, GLES3 context, shader/program compilation, deterministic
  pixel readback, complete FBO, presentation, frame-120 heartbeat, no new crash,
  and visually inspected RGB-triangle screenshots. The final post-review run
  also proves `scene_active` precedes frame 1 and that termination returns exit
  code 0, but its portrait-launch screenshot exposes the known 90-degree scene
  orientation failure. The current macOS suite also passes 24/24 tests and the
  iOS-only bridge does not leak into the desktop PsyCross archive.
- Passing physical renderer evidence is under
  `tmp/validation/2026-08-15-physical-renderer-smoke/`, with the current
  post-review run indexed in `post-review-paused-start/README.md`: signed
  Release build, install/launch over verified wired USB, Apple A19 Pro GLES3
  context, `scene_active` before rendering, deterministic readback and frame-1
  presentation PASS, frame-120 heartbeat, a visually inspected orientation-
  correct 2868x1320 RGB triangle, graceful exit code 0, and zero matching crash
  reports. Both the bootstrap and distinct smoke bundles remain installed.
- Scratch-only full iOS backend compile/link audit passes for arm64 Simulator
  and iphoneos with SDL2, OpenAL, FFmpeg, PsyCross, all portable libraries, and
  all 11 backend objects. It was intentionally not launched because the scratch
  binary has no scene owner. Evidence and the exact required CMake delta are in
  `tmp/validation/2026-08-15-ios-game-smoke-link-audit/README.md`.

## Not yet verified

- The Simulator-only app-sandbox copy will be deleted if that Simulator app is
  uninstalled; it is not the production persistence design.
- USB-C or Bluetooth input from a physical Xbox/PlayStation/MFi controller. The
  device currently reports no extended controller; mapping is synthetic only.
- SDL-owned input from a real controller, audio, FMV, retail guest/game boot,
  and gameplay.
- The RGB triangle proves the SDL/PsyCross GLES context, native framebuffer,
  presentation boundary, and lifecycle bridge. It does not yet exercise the
  real LIBGPU textured/alpha/depth primitive variants or the guest interpreter.
- Correct orientation when the app is launched from a portrait scene. The
  current Simulator screenshot is intentionally retained as failing evidence.

## Known issues

- AppleClang warnings remain in upstream code; bring-up presets set
  `SF_WARNINGS_AS_ERRORS=OFF`.
- Signing remains disabled by default. A separate ignored build tree uses the
  user's local automatic signing settings; do not record them in source or docs.
- OpenGL ES is deprecated on iOS. The GLES3 path is now runtime-validated as a
  bring-up bridge; the production renderer still needs a Metal backend.
- SDL2 2.32.10 emits two unbalanced UIKit appearance-transition warnings when
  its legacy window is attached to the active scene. More importantly, a
  portrait-launch Simulator scene retains portrait geometry and displays the
  landscape render rotated 90 degrees. Rendering/readback remains stable, but
  this bridge is not production-correct. Backport SDL3-style scene support and
  prove orientation before any game-integration claim.
- The full PsyCross backend's desktop CMake path still requires iOS-specific
  OpenGLES, FFmpeg static-import, and `Threads::Threads` handling before a
  tracked game-smoke target can configure normally.
- The final controller path must be `GCController -> SDL2 iOS backend ->
  SDL_GameController -> PsyCross/portable input`; disable the native diagnostic
  bridge once SDL owns controller handlers.

## Next steps

1. Backport the audited SDL2 UIScene/window lifecycle changes, fix and visually
   prove portrait-to-landscape negotiation, then use that production scene owner
   for game integration.
2. Apply the proven iOS full-backend dependency/CMake split and add a distinct
   scene-aware game-smoke bundle.
3. Add a ROM-free PsyCross/LIBGPU textured/alpha/depth primitive smoke before
   reading retail media.
4. Add a bounded, interactive external-CUE boot smoke: retain/freeze the folder
   lease, coordinate full CUE+BIN contents, verify the supported build, load the
   first mission, bootstrap the guest, and render one coherent frame without
   copying media.
5. Refactor blocking host loops into lifecycle-driven steps before continuous
   gameplay; then test a real MFi-compatible controller, audio, FMV, and resume.

## Pushed milestones

- `be5bc53` — persistent iOS disc and controller bootstrap.
- `4b434ce` — pinned iOS SDL2/OpenAL Soft/FFmpeg dependency bootstrap.
- `625320b` — PsyCross iOS GLES portability and link plumbing.
- `84833b8` — ROM-free iOS PsyCross renderer smoke checkpoint.

## Git policy

- Public fork: `https://github.com/negroISO/SF-pc-port.git`
- Upstream: `https://github.com/Madxbio97/SF-pc-port.git`
- Never commit ROMs, retail-derived data, `out/`, `tmp/`, credentials, signing
  identities, device identifiers, or provisioning material.
