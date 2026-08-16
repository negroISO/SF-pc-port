# Third-party software and assets

The repository contains project-owned code plus a modified vendored copy of
PsyCross. Release packages also dynamically link several libraries installed by
the vcpkg manifest.

| Component | Use | License source |
| --- | --- | --- |
| PsyCross | PS1-compatible platform/rendering backend | `external/PsyCross/LICENSE` |
| SMAA 2.8 | Morphological antialiasing shader and lookup textures | external/PsyCross/src/render/smaa/LICENSE.txt |
| SDL2 | Window, input and platform services | vcpkg package copyright file |
| OpenAL Soft | Native audio output | vcpkg package copyright file |
| FFmpeg | STR/FM​​V demux/decode and audio conversion | vcpkg package copyright file |
| fmt | Formatting support used by the backend | vcpkg package copyright file |
| Industry Bold (RUS by Slavchansky) | User-supplied source face for the generated Russian font atlas; the TTF is not redistributed | `tools/fonts/industry/COPYRIGHT.txt` |
| Microsoft Visual C++ Runtime | Windows runtime libraries in binary releases | Applicable Microsoft license terms |

## Pinned iOS source builds

`tools/build-ios-deps.sh` builds target libraries entirely below
`out/ios-deps/` on the external workspace. It does not install or link target
libraries from Homebrew. Source versions and archive SHA-256 values are locked
in `deps/ios-deps.lock`:

| Component | Version | iOS configuration | Upstream source |
| --- | --- | --- | --- |
| SDL2 | 2.32.10 | Static arm64; UIKit, GameController/MFi, GLES and Metal platform support | <https://github.com/libsdl-org/SDL/releases/tag/release-2.32.10> |
| OpenAL Soft | 1.25.2 | Static arm64; CoreAudio and null backends only; bundled HRTF data disabled | <https://openal-soft.org/> |
| FFmpeg | 8.1.2 | Static arm64 LGPL build; only `str` demux, `mdec` and `adpcm_xa` decode, plus `avformat`, `avcodec`, `avutil`, `swresample` and `swscale` | <https://ffmpeg.org/download.html> |

SDL's pinned digest matches the official GitHub release API. OpenAL Soft and
FFmpeg do not publish SHA-256 sidecars; their lock values were calculated from
the official HTTPS release archives. FFmpeg also publishes an upstream detached
signature next to its source archive. The bootstrap always verifies SHA-256
before extraction.

OpenAL Soft 1.25.2 enables Clang's experimental `-Wfunction-effects` probe and
then treats it as an error. Xcode 27 rejects two CoreAudio callback conversions
under that diagnostic, so the build recipe disables that optional warning probe
without patching upstream source.

The release packager copies the exact dependency notices into its `licenses/`
directory and writes `THIRD_PARTY_NOTICES.txt` at the package root.

PsyCross is vendored rather than referenced as a submodule because this port
requires local GPU, GTE, PGXP, framebuffer, filtering, input and crash-handling
changes. Its original upstream is <https://github.com/OpenDriver2/PsyCross> and
the vendored base revision is `e56e4cd`.

The `assets/dossiers/screens` images and launcher icon are presentation assets
for this fan project. They do not grant any rights to *Syphon Filter*, its
characters, artwork or trademarks. Do not reuse or redistribute original game
data outside the rights granted by its owner.
