# AI handoff

## Updated

2026-08-16 10:08 CDT

## Workspace

`/Volumes/iPhone/PS1_Rrecomps/SF1`, active feature branch
`ios-guest-renderer-smoke` from pushed `ios-port` commit `108922e`. Public `origin` is
`https://github.com/negroISO/SF-pc-port.git`; never commit retail media,
derived retail data, device/signing identifiers, credentials, or anything under
`out/`/`tmp/`.

The SDL-owned renderer milestone is committed and pushed as `c292495`. The
full guest-renderer checkpoint is committed and pushed as `f348406` and remains
isolated on the feature branch. Its physical-device gate now passes after the
verified presentation-clock fix committed as `900009c`; do not merge to
`ios-port` without an explicit review/merge decision.

## Current status

- Physical guest rendering now passes on the iPhone. The first resumed run
  exposed a real black-screen regression: guest frame 48 / sequence 50 was
  coherent, but composed map fade remained 240, so the strict gate returned
  `visibility_timeout` before renderer submission. `GameplaySession::update()`
  now advances its native presentation clock once per authoritative 20 Hz
  update. The exact rebuilt run passed at guest frame 29 / sequence 31 with fade
  32, 2,914 submitted primitives, complete draw/read FBO 2, 388,800 readable
  opaque pixels, 194,058 nonuniform pixels, 807 RGB buckets, clean GL errors,
  and coherent/visible/observer flags all set. Total time was 806.376 ms.
- `guest-run2-pass.png` was visually inspected: it contains a recognizable
  rendered Mission 1 scene rather than the pre-fix black screen. Pronounced
  striped/fragmented raster output remains visible, so this checkpoint proves
  bounded production-path submission/readback/presentation, not final visual
  fidelity. The guest added no crash report. The signed bootstrap was restored
  again with same-ID container access preserved and was visually verified with
  the external disc ready.
- The clock fix passes macOS build/CTest 24/24, arm64 Simulator Release and
  signed arm64 device Release guest builds, `git diff --check`, and strict/deep
  signature verification. Evidence is under
  `tmp/validation/2026-08-16-ios-guest-renderer-smoke-resume/`.
- Active continuation is isolated on `ios-guest-renderer-smoke`. The full iOS
  backend split, exact FFmpeg/OpenAL/SDL/OpenGLES closure, bounded guest target,
  and one-presentation production scene bridge build and link for arm64
  Simulator and device. Portable tests are 24/24 PASS and `git diff --check`
  passes. The final shared-ID Simulator Release app and signed device Release
  app build; code signature and full-screen plist checks pass. Runtime
  physical framebuffer/readback/visual proof now passes with the visual-fidelity
  limitation recorded below.
- The ROM-free renderer now uses `SDL_UIKitRunApp` and SDL's patched
  `SDLUIKitSceneDelegate`; the competing custom scene delegate, CADisplayLink,
  manifest, and temporary PsyCross late-attach bridge are removed. Exact-source
  arm64 Simulator/device builds pass, and Simulator scene ownership, known RGB
  readback, FBO presentation, and visual triangle inspection pass. Evidence is
  `tmp/validation/2026-08-15-sdl-owner-conversion/`.
- The iOS bootstrap preserves a security-scoped bookmark to a user-selected
  external Files/USB/iCloud folder. It validates exactly one top-level CUE and
  its sibling BIN and does not copy either into the app sandbox.
- A bounded `Run Mission 1 Boot Smoke` action now coordinates full access to the
  retained directory/CUE/BIN, revalidates the same pair, opens the supported
  build, loads Mission 1, constructs `LegacyFirstMissionRuntime`, validates its
  initial frame, advances one host update with an empty pad, and requires a
  fresh coherent presentation.
- The smoke blocks while a replacement folder is validating, invalidates stale
  green PASS status after disc-selection changes, and sanitizes parser failures
  so provider paths are not written to shareable console/UI output.
- Normal launches do not read retail media. `--sf-run-boot-smoke` is an explicit
  operator-only launch argument and only runs after an already-authorized saved
  folder becomes ready. It is not wired to CTest.
- The original physical-device boot crash was reproduced and fixed. Pre-fix
  `Spu::reset()` created a 594,512-byte arm64 stack frame from `*state_ = {};`.
  Commit `fccd9a7` reconstructs `SpuState` directly in its heap allocation and
  adds an exact-reset regression.
- Final exact-source physical smoke passes at guest frame 1 / presentation
  sequence 2. A profiled run reached that state in 191.188 ms; a clean
  post-review run took 202.929 ms. A complete 15-second CPU Profiler trace
  exported 1,566 samples. `R3000Runtime::step()` accounts for 50.74% of sampled
  cycle weight and is the leading CPU optimization target.
- At the earlier bounded-boot milestone, its exact final source rebuilt for
  arm64 Simulator and signed arm64 device, installed over the existing bundle,
  visually displayed PASS, and produced no new crash report. The signed
  bootstrap is installed now after the current locked-device launch attempt.
- Commit `e8c2803` tracks and pins the SDL2 2.32.10 iOS UIScene/orientation
  backport. Fresh Simulator/device dependency builds and link smokes pass. Its
  standalone Simulator GL lifecycle, orientation, background/foreground, and
  teardown smokes pass without the prior no-scene assertion.
- The ROM-free PsyCross renderer checkpoint remains pushed in `84833b8` and
  previously passed on Simulator and physical iPhone. The bootstrap/guest smoke
  now has a feature-branch bounded bridge that connects one coherent visible
  guest presentation to the production renderer and captures pre-present
  FBO/pixel evidence; the physical run now passes.
- Simulator preflight found no installed `com.syphonfilter.port` app or reusable
  data container on any available Simulator. The arm64 bootstrap restore app is
  available at `out/ios-simulator/apps/sf_ios/Debug-iphonesimulator/`.
- The retained Simulator retail staging directory is empty, so the legal retail
  render smoke cannot run there without another user-provided copy. The
  no-media launch follows the new asynchronous provider path, fails cleanly at
  directory discovery in 4.525 ms, and does not deadlock. Same-ID
  bootstrap/guest/restore installs preserve a synthetic Documents probe; the
  bootstrap was visually verified and the Simulator returned to Shutdown.
- A non-retail synthetic one-sector CUE/BIN fixture exercised all three final
  intents on Simulator: disc validation passed in 0.926 ms and the unsupported
  fixture then failed at disc open as expected. The fixture was removed, the
  bootstrap restored, and the Simulator returned to Shutdown.
- Guest disc access now performs directory and CUE discovery on a serial worker,
  holds explicit directory/CUE/BIN `NSFileAccessIntent`s, uses each intent's
  coordinated URL, and dispatches only PsyCross initialization/rendering to the
  SDL/UIKit main thread. Provider waits no longer synchronously block main.
- Enabling the C language before IPO when `SF_ENABLE_PSYCROSS=ON` fixes native
  PsyCross generation. Fresh native macOS configure and clean backend build
  pass without the temporary language adapter.
- The earlier locked-device launch was superseded by the successful unlocked,
  wired physical run. The bootstrap is again the installed and visually
  verified app.
- The native GameController diagnostic bridge recognizes the intended extended
  MFi-compatible Xbox/DualShock/DualSense mapping. Final gameplay input must be
  owned by SDL2; no real physical controller has been tested yet.

## Verified evidence

All evidence stays ignored on the external volume.

### SPU fix

- `tmp/validation/2026-08-15-spu-stack-reset/README.md`
- exact pre-fix arm64 frame: 594,512 bytes
- fixed Release/Debug arm64 frames: 48/32 bytes
- focused SPU stack-limit smokes: PASS
- macOS build + CTest: 24/24 PASS

### Bounded boot — Simulator

- `tmp/validation/2026-08-15-bounded-game-boot-smoke/README.md`
- Debug build/install/auto-run: PASS
- guest frame 1 / sequence 2 coherent: PASS
- visually inspected green PASS screenshot: PASS

### Bounded boot — physical device

- `tmp/validation/2026-08-15-physical-bounded-game-boot-smoke/README.md`
- original `.ips` preserves the `___chkstk_darwin -> Spu::reset()` crash
- final signed Release build/install/launch: PASS
- exact-final profiled run: 191.188 ms through guest frame 1
- complete `final-reviewed-boot-cpu.trace`: PASS; 1,566 exported CPU rows
- final readable screenshot: visually inspected PASS
- post-run crash query: zero new reports

### SDL2 scene backport

- `tmp/validation/2026-08-15-sdl-scene-production-audit/README.md`
- tracked patch SHA-256:
  `d4a047bb8edc8852a46bd3b6584409d9badb568e372e440584bf30e9e2b32ea5`
- fresh arm64 Simulator/device dependency rebuild + link smoke: PASS
- Simulator scene/GL/orientation/lifecycle/teardown smoke: PASS
- independent review: approved for the intended single-scene fullscreen iPhone
  path with minimum iOS 17

### Root integration checks

- `tmp/validation/2026-08-15-final-integration/macos-build-ctest.log`:
  24/24 PASS
- `tmp/validation/2026-08-15-final-integration/ios-shell-builds.log`:
  Simulator Debug and iphoneos Release shell builds PASS
- `tmp/validation/2026-08-15-final-integration/diff-script-security-check.log`:
  diff/shell/hash/verify-only checks PASS
- independent final source/public-safety review: APPROVE

### Guest renderer checkpoint

- `tmp/validation/2026-08-15-ios-guest-renderer-smoke/`
- final arm64 Simulator Release build: PASS
- final signed arm64 device Release build and `codesign --verify`: PASS
- native macOS PsyCross configure + clean backend build: PASS
- portable macOS build + CTest: 24/24 PASS
- Simulator async no-media and synthetic three-intent paths: PASS
- same-ID Simulator data preservation probe: PASS
- independent async coordination/lifetime/public-log review: APPROVE
- original physical install: PASS; launch/render: BLOCKED — DEVICE LOCKED
  (superseded by the resumed physical evidence below)
- physical signed bootstrap reinstall + container access: PASS

### Guest renderer — resumed physical device

- `tmp/validation/2026-08-16-ios-guest-renderer-smoke-resume/`
- pre-fix black-screen `visibility_timeout` reproduced: PASS
- presentation-clock source fix: PASS
- macOS build + CTest: 24/24 PASS
- arm64 Simulator Release build: PASS
- signed arm64 device Release build + strict/deep signature check: PASS
- exact physical render/FBO/readback/pixel gate: PASS in 806.376 ms
- screenshot: visible Mission 1 scene; striped/fragmented fidelity limitation
  recorded
- post-run crash delta: zero
- final signed-bootstrap restore, container access and visual check: PASS

## Not yet verified

- Continuous guest-driven drawing, frame pacing, touch controls, saves,
  pause/resume during active gameplay, or mission progression.
- Real USB-C/Bluetooth Xbox, DualShock 4, DualSense, or other MFi controller
  through SDL2's final gameplay path.
- Audio, XA playback, FMV video, interruptions, route changes, or audible output.
- A Metal gameplay renderer. The current ROM-free renderer uses deprecated
  OpenGL ES/PsyCross as a bring-up bridge.
- Physical-device runtime of the exact standalone SDL scene harness, iOS 17
  runtime, external displays, multiple/reconnected scenes, or cold URL delivery.
- Visual correctness beyond one bounded guest frame. The passing physical
  screenshot is recognizable but has pronounced striped/fragmented output.

## Known limitations

- The earlier boot smoke advances one guest host update. This renderer smoke
  permits at most 48 empty-pad updates to reach a visible coherent frame,
  presents exactly once, and has no lifecycle-driven game loop. Neither is a
  playable port.
- The tracked SDL patch targets a single fullscreen application scene. Custom
  `UIApplicationMain` hosts must use SDL's wrapper or forward/dedupe callbacks;
  external display and multi-scene routing remain unsupported.
- AppleClang emits existing defaulted-comparison warnings in legacy bridge
  types; bring-up presets keep warnings-as-errors disabled.
- Signing is disabled by default. Local automatic-signing settings live only in
  ignored build/evidence trees.

## Next steps

1. Investigate the pronounced striped/fragmented raster visible in the passing
   physical screenshot before treating the OpenGL ES bridge as visually
   correct or beginning continuous gameplay.
2. Recopy the legal disc pair to Simulator Documents/Ps1 only if Simulator
   retail parity is needed; the retained staging directory is currently empty.
3. Profile continuous execution. Start with the R3000 interpreter step/pump hot
   path identified by the physical CPU trace; optimize only against comparable
   traces and deterministic tests.
4. Route SDL game-controller input into the portable pad state, then physically
   smoke Xbox/PlayStation/MFi USB-C and Bluetooth controllers.
5. Add OpenAL audio/XA and FFmpeg FMV smokes, then design the production Metal
   backend rather than treating OpenGL ES as the final renderer.

## Pushed milestones

- `be5bc53` — persistent iOS disc and controller bootstrap
- `4b434ce` — pinned iOS SDL2/OpenAL Soft/FFmpeg dependency bootstrap
- `625320b` — PsyCross iOS GLES portability and link plumbing
- `84833b8` — ROM-free iOS PsyCross renderer smoke checkpoint
- `bf51e50` — renderer handoff
- `fccd9a7` — SPU reset stack-overflow fix
- `e8c2803` — SDL2 iOS scene lifecycle backport
- `1489d7d` — bounded iOS external-disc guest boot smoke
- `c292495` — SDL-owned iOS renderer scene conversion
- `f348406` — bounded iOS guest renderer smoke checkpoint; physical runtime pending
- `900009c` — advance gameplay presentation clock; physical guest render PASS
