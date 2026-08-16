# AI handoff

## Updated

2026-08-16 00:00 CDT

## Workspace

`/Volumes/iPhone/PS1_Rrecomps/SF1`, active feature branch
`ios-guest-renderer-smoke` from pushed `ios-port` commit `108922e`. Public `origin` is
`https://github.com/negroISO/SF-pc-port.git`; never commit retail media,
derived retail data, device/signing identifiers, credentials, or anything under
`out/`/`tmp/`.

The SDL-owned renderer milestone is committed and pushed as `c292495`. The
full guest-renderer checkpoint is committed and pushed as `f348406`, remains
isolated on the feature branch, and must not merge to `ios-port` until its
physical-device runtime smoke passes.

## Current status

- Active continuation is isolated on `ios-guest-renderer-smoke`. The full iOS
  backend split, exact FFmpeg/OpenAL/SDL/OpenGLES closure, bounded guest target,
  and one-presentation production scene bridge build and link for arm64
  Simulator and device. Portable tests are 24/24 PASS and `git diff --check`
  passes. The final shared-ID Simulator Release app and signed device Release
  app build; code signature and full-screen plist checks pass. Runtime
  framebuffer/visual proof is still pending.
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
  FBO/pixel evidence; it has not yet run.
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
- The exact signed guest app installed over the physical-phone bootstrap, but
  SpringBoard denied launch because the device was locked; no guest code or
  retail access ran. The signed bootstrap was immediately reinstalled and app
  container access reverified. Launch/screenshot verification remains pending
  an unlocked phone.
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
- physical install: PASS; launch/render: BLOCKED — DEVICE LOCKED
- physical signed bootstrap reinstall + container access: PASS

## Not yet verified

- Continuous gameplay, guest-driven drawing, frame pacing, touch controls, saves,
  pause/resume during active gameplay, or mission progression.
- Real USB-C/Bluetooth Xbox, DualShock 4, DualSense, or other MFi controller
  through SDL2's final gameplay path.
- Audio, XA playback, FMV video, interruptions, route changes, or audible output.
- A Metal gameplay renderer. The current ROM-free renderer uses deprecated
  OpenGL ES/PsyCross as a bring-up bridge.
- Physical-device runtime of the exact standalone SDL scene harness, iOS 17
  runtime, external displays, multiple/reconnected scenes, or cold URL delivery.
- Physical-device guest rendering/FBO readback for this feature checkpoint. The
  only launch attempt was rejected by SpringBoard before app code ran because
  the phone was locked.

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

1. Unlock the connected phone, reinstall the signed guest over the restored
   bootstrap, run `--sf-run-guest-render-smoke`, capture its timing/FBO/pixel
   log and screenshot, query crash deltas, then reinstall and visually verify
   the bootstrap again.
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
