# AI handoff

## Updated

2026-08-15

## Workspace

`/Volumes/iPhone/PS1_Rrecomps/SF1` on branch `ios-port`, based on upstream
commit `a11020bbf8ea136e1685edfe29217e7c965b49c9`.

## Current status

- Portable runtime builds for iPhone arm64.
- Native Objective-C++/UIKit bootstrap links `sf_game` and reports the supported
  build count.
- Unsigned iPhone application and arm64 Simulator application build.
- UIKit scene lifecycle launches in an iPhone 17 Pro Simulator and visibly
  reports one linked supported build.
- A user-owned Apple Development signature installs and launches the bootstrap
  over Wi-Fi on an iPhone 17 Pro Max running iOS 27.0.
- Renderer, game execution, disc import, audio and input are not connected.
- Legal local BIN/CUE staging directory: ignored `tmp/discs/sf1/`.

## Verified baseline

- `cmake --preset ios-device`
- `cmake --build --preset ios-device-core-release`
- `cmake --build --preset ios-device-shell-release`
- `cmake --preset ios-simulator`
- `cmake --build --preset ios-simulator-shell-debug`
- Native macOS deterministic suite: 23/23 CTest tests passed from the external
  build tree `out/macos-validation`.
- Device product:
  `out/ios-device/apps/sf_ios/Release-iphoneos/SyphonFilter.app`
- Simulator product:
  `out/ios-simulator/apps/sf_ios/Debug-iphonesimulator/SyphonFilter.app`

The apps were compiled, linked and bundle-validated. The Simulator bootstrap
was launched and visually inspected after adding the required UIScene
lifecycle. Evidence is under
`tmp/validation/2026-08-15-rules-publish/`, including
`ios-simulator-runtime-smoke-scene-fix.log` and
`ios-simulator-bootstrap-landscape.jpg`.

Physical-device evidence is under
`tmp/validation/2026-08-15-iphone17promax-device/`. The signed arm64 app was
verified with `codesign`, installed with `devicectl`, remained alive through a
sustained process check, produced no matching device crash report, and was
visually inspected in `iphone17promax-bootstrap.png`.

## Known issues

- AppleClang warnings remain in upstream code; bring-up presets currently set
  `SF_WARNINGS_AS_ERRORS=OFF`.
- Signing remains disabled by default in the checked-in preset. A separate
  external build tree was successfully signed with the user's development team.
- PsyCross currently selects desktop OpenGL for `__APPLE__`; iPhone needs the
  GLES3 path or a native Metal backend.
- SDL2, OpenAL Soft and FFmpeg iOS dependency builds are not configured.

## Next steps

1. Package SDL2, OpenAL Soft and FFmpeg entirely under the external volume.
2. Patch PsyCross for `TARGET_OS_IPHONE` GLES3 and bring up a controller-only
   known scene.
3. Add CUE+BIN document import and Application Support storage.

## Git policy

- Public fork: `https://github.com/negroISO/SF-pc-port.git`
- Upstream: `https://github.com/Madxbio97/SF-pc-port.git`
- Do not commit ROMs, retail-derived data, `out/`, `tmp/`, credentials or
  provisioning material.
