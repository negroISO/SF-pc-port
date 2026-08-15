# iOS port bootstrap

The current iOS target proves that the portable gameplay runtime links into a
native UIKit application. It does not yet include PsyCross, rendering, audio,
disc import or game execution.

No game image is required for this bootstrap and no retail data belongs in the
repository.

## Requirements

- Xcode with the iOS device and Simulator SDKs.
- CMake 3.24 or newer.
- An Apple Silicon Mac for the checked-in arm64 Simulator preset.

The initial deployment target is iOS 17.0 and the bootstrap targets iPhone.

## Configure and build

Start every project shell by loading the external-volume environment:

```sh
cd /Volumes/iPhone/PS1_Rrecomps/SF1
source tools/project-env.sh
```

This keeps project temporary files and supported tool caches under the external
volume. Do not use `/tmp`, a checkout under the internal drive, or Xcode's
default DerivedData directory for this project.

Build the portable core for an iPhone device:

```sh
cmake --preset ios-device
cmake --build --preset ios-device-core-release
```

Build the unsigned native bootstrap application:

```sh
cmake --build --preset ios-device-shell-release
```

Build the Simulator bootstrap application:

```sh
cmake --preset ios-simulator
cmake --build --preset ios-simulator-shell-debug
```

Generated Xcode projects and products are under `out/`, which is ignored by
Git.

## Run on a physical device

Code signing is disabled by default so command-line validation does not require
a personal team. Regenerate the device project with signing enabled, then open
the generated Xcode project and select the team for the `sf_ios` target:

```sh
cmake --preset ios-device --fresh -DSF_IOS_CODE_SIGNING=ON \
  -DSF_IOS_BUNDLE_IDENTIFIER=com.example.syphonfilter
open out/ios-device/SyphonFilterPC.xcodeproj
```

Use a bundle identifier owned by the selected Apple Developer team.

## Next milestone

Keep `sf_game` and the project-level `GR_*` presentation boundary unchanged.
The next target is a controller-only on-device scene bootstrap using the
existing PsyCross OpenGL ES 3 path. That requires iOS builds of SDL2, OpenAL
Soft and FFmpeg plus iOS-specific GLES headers and framework links.
