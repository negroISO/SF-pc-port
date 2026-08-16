# AI handoff

## Updated

2026-08-15 22:31 CDT

## Workspace

`/Volumes/iPhone/PS1_Rrecomps/SF1`, branch `ios-port`. Public `origin` is
`https://github.com/negroISO/SF-pc-port.git`; never commit retail media,
derived retail data, device/signing identifiers, credentials, or anything under
`out/`/`tmp/`.

Current public HEAD is `1489d7d`. The SPU stack fix, SDL2 scene backport, and
bounded iOS external-disc boot action are independently reviewed, verified,
committed, and pushed.

## Current status

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
- The exact final source rebuilt for arm64 Simulator and signed arm64 device,
  installed over the existing bundle, visually displayed PASS, and produced no
  new crash report. The app remains launched on the connected phone at the PASS
  screen.
- Commit `e8c2803` tracks and pins the SDL2 2.32.10 iOS UIScene/orientation
  backport. Fresh Simulator/device dependency builds and link smokes pass. Its
  standalone Simulator GL lifecycle, orientation, background/foreground, and
  teardown smokes pass without the prior no-scene assertion.
- The ROM-free PsyCross renderer checkpoint remains pushed in `84833b8` and
  previously passed on Simulator and physical iPhone. The bootstrap/guest smoke
  does not yet connect that renderer to guest presentation data.
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

## Known limitations

- The bounded smoke deliberately advances only one guest host update and then
  destroys the temporary runtime. It is proof of boot/presentation coherence,
  not a playable port.
- The tracked SDL patch targets a single fullscreen application scene. Custom
  `UIApplicationMain` hosts must use SDL's wrapper or forward/dedupe callbacks;
  external display and multi-scene routing remain unsupported.
- AppleClang emits existing defaulted-comparison warnings in legacy bridge
  types; bring-up presets keep warnings-as-errors disabled.
- Signing is disabled by default. Local automatic-signing settings live only in
  ignored build/evidence trees.

## Next steps

1. Apply the proven full iOS backend CMake split and use the patched SDL scene
   owner for a distinct guest game-smoke bundle.
2. Feed the bounded coherent presentation into the verified PsyCross renderer;
   visually validate guest primitives before adding a lifecycle-driven loop.
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
