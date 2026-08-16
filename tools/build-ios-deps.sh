#!/bin/sh

# Build the pinned iOS dependency set without installing target libraries on
# the Mac. Downloads, sources, build trees, prefixes, logs and smoke products
# stay below the external SF1 checkout.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$REPO_ROOT"
# shellcheck source=project-env.sh
. "$REPO_ROOT/tools/project-env.sh" >/dev/null

LOCK_FILE="$REPO_ROOT/deps/ios-deps.lock"
DEPS_ROOT="$REPO_ROOT/out/ios-deps"
DOWNLOAD_ROOT="$DEPS_ROOT/downloads"
SOURCE_ROOT="$DEPS_ROOT/src"
BUILD_ROOT="$DEPS_ROOT/build"
INSTALL_ROOT="$DEPS_ROOT/install"
LOG_ROOT="$DEPS_ROOT/logs"
SMOKE_ROOT="$DEPS_ROOT/smoke"
PATCH_ROOT="$REPO_ROOT/deps/patches"
SDL2_PATCH_VERSION=2.32.10
SDL2_PATCH_FILE="$PATCH_ROOT/sdl2-$SDL2_PATCH_VERSION-ios-uiscene.patch"
SDL2_PATCH_SHA256=d4a047bb8edc8852a46bd3b6584409d9badb568e372e440584bf30e9e2b32ea5
DEPLOYMENT_TARGET=${SF_IOS_DEPLOYMENT_TARGET:-17.0}
RECIPE_VERSION=2

PLATFORM=all
MODE=build
CLEAN=0
JOBS=${SF_IOS_DEPS_JOBS:-}
LOCK_ROWS=

usage() {
    cat <<'EOF'
Usage: tools/build-ios-deps.sh [options]

Build pinned static SDL2, OpenAL Soft and minimal FFmpeg libraries for iOS.

Options:
  --platform PLATFORM  iphoneos, iphonesimulator, or all (default: all)
  --jobs N             Parallel build jobs (default: host logical CPU count)
  --download-only      Fetch and SHA-256-verify archives, then stop
  --verify-only        Validate the lock and verify any cached archives
  --clean              Remove selected build/install/log/smoke trees first
  -h, --help           Show this help

Outputs:
  out/ios-deps/install/iphoneos
  out/ios-deps/install/iphonesimulator

Set SF_IOS_DEPLOYMENT_TARGET to override the default minimum iOS version 17.0.
The script sources tools/project-env.sh itself and never installs target
libraries through Homebrew.
EOF
}

die() {
    echo "build-ios-deps: $*" >&2
    exit 1
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die "required tool is missing: $1"
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

sha256_text() {
    /usr/bin/shasum -a 256 | awk '{print $1}'
}

safe_remove_tree() {
    local path
    path=$1
    case "$path" in
        "$DEPS_ROOT"/*) rm -rf -- "$path" ;;
        *) die "refusing to remove path outside $DEPS_ROOT: $path" ;;
    esac
}

run_logged() {
    local label log status
    label=$1
    log=$2
    shift 2
    mkdir -p "$(dirname -- "$log")"
    printf '%s\n' "[$label]"
    if "$@" >"$log" 2>&1; then
        printf '%s\n' "  ok: $log"
    else
        status=$?
        echo "  failed (exit $status): $log" >&2
        tail -80 "$log" >&2 || true
        exit "$status"
    fi
}

run_logged_in_dir() {
    local label log directory status
    label=$1
    log=$2
    directory=$3
    shift 3
    mkdir -p "$(dirname -- "$log")"
    printf '%s\n' "[$label]"
    if (cd "$directory" && "$@") >"$log" 2>&1; then
        printf '%s\n' "  ok: $log"
    else
        status=$?
        echo "  failed (exit $status): $log" >&2
        tail -80 "$log" >&2 || true
        exit "$status"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            [ "$#" -ge 2 ] || die "--platform needs a value"
            PLATFORM=$2
            shift 2
            ;;
        --platform=*)
            PLATFORM=${1#*=}
            shift
            ;;
        --jobs)
            [ "$#" -ge 2 ] || die "--jobs needs a value"
            JOBS=$2
            shift 2
            ;;
        --jobs=*)
            JOBS=${1#*=}
            shift
            ;;
        --download-only)
            MODE=download
            shift
            ;;
        --verify-only)
            MODE=verify
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (use --help)"
            ;;
    esac
done

case "$PLATFORM" in
    iphoneos|iphonesimulator|all) ;;
    *) die "unsupported platform: $PLATFORM" ;;
esac
case "$MODE" in
    build|download|verify) ;;
    *) die "internal mode error: $MODE" ;;
esac
case "$DEPLOYMENT_TARGET" in
    ''|*[!0-9.]*) die "invalid SF_IOS_DEPLOYMENT_TARGET: $DEPLOYMENT_TARGET" ;;
esac

need_tool awk
need_tool grep
need_tool tar
need_tool patch
need_tool /usr/bin/shasum
[ -f "$LOCK_FILE" ] || die "dependency lock is missing: $LOCK_FILE"

LOCK_ROWS="$TMPDIR/sf1-ios-deps-lock.$$.txt"
trap 'rm -f -- "$LOCK_ROWS"' EXIT HUP INT TERM
awk 'NF && $0 !~ /^[[:space:]]*#/ { print }' "$LOCK_FILE" >"$LOCK_ROWS"

validate_lock() {
    local count id rows version archive sha url
    count=$(wc -l <"$LOCK_ROWS" | tr -d '[:space:]')
    [ "$count" = 3 ] || die "lock must contain exactly 3 dependency rows (found $count)"
    if awk -F '|' 'NF != 5 { exit 1 }' "$LOCK_ROWS"; then :; else
        die "each lock row must contain exactly 5 pipe-delimited fields"
    fi

    while IFS='|' read -r id version archive sha url; do
        [ -n "$id" ] && [ -n "$version" ] && [ -n "$archive" ] &&
            [ -n "$sha" ] && [ -n "$url" ] || die "lock contains an empty field"
        case "$archive" in
            */*|*'..'*) die "unsafe archive name in lock: $archive" ;;
        esac
        [ "${#sha}" -eq 64 ] || die "invalid SHA-256 length for $id"
        case "$sha" in
            *[!0-9a-f]*) die "invalid SHA-256 characters for $id" ;;
        esac
        case "$id:$url" in
            sdl2:https://github.com/libsdl-org/SDL/releases/download/*) ;;
            openal-soft:https://openal-soft.org/openal-releases/*) ;;
            ffmpeg:https://ffmpeg.org/releases/*) ;;
            *) die "non-official or mismatched source URL for $id: $url" ;;
        esac
    done <"$LOCK_ROWS"

    for id in sdl2 openal-soft ffmpeg; do
        rows=$(awk -F '|' -v id="$id" '$1 == id { count++ } END { print count + 0 }' "$LOCK_ROWS")
        [ "$rows" = 1 ] || die "lock must contain one row for $id (found $rows)"
    done
}

dep_field() {
    local id field
    id=$1
    field=$2
    awk -F '|' -v id="$id" -v field="$field" '$1 == id { print $field; exit }' "$LOCK_ROWS"
}

verify_sdl2_patch() {
    local version actual
    version=$(dep_field sdl2 2)
    [ "$version" = "$SDL2_PATCH_VERSION" ] ||
        die "SDL2 patch targets $SDL2_PATCH_VERSION, but the lock pins $version"
    [ -f "$SDL2_PATCH_FILE" ] || die "SDL2 patch is missing: $SDL2_PATCH_FILE"
    actual=$(sha256_file "$SDL2_PATCH_FILE")
    [ "$actual" = "$SDL2_PATCH_SHA256" ] ||
        die "SDL2 patch SHA-256 mismatch: expected $SDL2_PATCH_SHA256, got $actual"
}

verify_archive() {
    local id archive expected actual
    id=$1
    archive=$2
    expected=$3
    actual=$(sha256_file "$archive")
    [ "$actual" = "$expected" ] ||
        die "$id archive SHA-256 mismatch: expected $expected, got $actual"
}

fetch_dependency() {
    local id archive_name expected url archive part
    id=$1
    archive_name=$(dep_field "$id" 3)
    expected=$(dep_field "$id" 4)
    url=$(dep_field "$id" 5)
    archive="$DOWNLOAD_ROOT/$archive_name"

    mkdir -p "$DOWNLOAD_ROOT"
    if [ ! -f "$archive" ]; then
        need_tool curl
        rm -f -- "$archive".part.*
        part="$archive.part.$$"
        rm -f -- "$part"
        printf '%s\n' "[download $id] $url"
        if ! curl --proto '=https' --tlsv1.2 --fail --location --show-error \
            --retry 3 --retry-all-errors --output "$part" "$url"; then
            rm -f -- "$part"
            die "download failed for $id"
        fi
        verify_archive "$id" "$part" "$expected"
        mv -- "$part" "$archive"
    else
        printf '%s\n' "[verify $id] $archive"
    fi
    verify_archive "$id" "$archive" "$expected"
}

source_directory_name() {
    local id version
    id=$1
    version=$(dep_field "$id" 2)
    case "$id" in
        sdl2) printf 'SDL2-%s\n' "$version" ;;
        openal-soft) printf 'openal-soft-%s\n' "$version" ;;
        ffmpeg) printf 'ffmpeg-%s\n' "$version" ;;
        *) die "unknown dependency id: $id" ;;
    esac
}

extract_dependency() {
    local id archive_name expected archive root_name source_dir stamp listing source_key
    id=$1
    archive_name=$(dep_field "$id" 3)
    expected=$(dep_field "$id" 4)
    archive="$DOWNLOAD_ROOT/$archive_name"
    root_name=$(source_directory_name "$id")
    source_dir="$SOURCE_ROOT/$root_name"
    stamp="$SOURCE_ROOT/.$root_name.sha256"
    source_key=$expected
    if [ "$id" = sdl2 ]; then
        source_key="$expected|$SDL2_PATCH_SHA256"
    fi

    if [ -d "$source_dir" ] && [ -f "$stamp" ] &&
        [ "$(cat "$stamp")" = "$source_key" ]; then
        return
    fi

    mkdir -p "$SOURCE_ROOT"
    listing="$TMPDIR/sf1-ios-deps-tar.$$.txt"
    tar -tf "$archive" >"$listing"
    if ! awk -v root="$root_name" '
        $0 != root && $0 != root "/" && index($0, root "/") != 1 { bad = 1 }
        END { exit bad }
    ' "$listing"; then
        rm -f -- "$listing"
        die "$id archive has entries outside expected root $root_name"
    fi
    rm -f -- "$listing"

    if [ -e "$source_dir" ]; then
        safe_remove_tree "$source_dir"
    fi
    rm -f -- "$stamp"
    printf '%s\n' "[extract $id] $source_dir"
    tar -xf "$archive" -C "$SOURCE_ROOT"
    [ -d "$source_dir" ] || die "$id archive did not create $source_dir"
    if [ "$id" = sdl2 ]; then
        run_logged_in_dir "SDL2 UIKit patch" "$LOG_ROOT/source/sdl2-patch.log" \
            "$source_dir" patch --batch --forward -p1 -i "$SDL2_PATCH_FILE"
    fi
    printf '%s\n' "$source_key" >"$stamp"
}

if [ -z "$JOBS" ]; then
    JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
fi
case "$JOBS" in
    ''|*[!0-9]*) die "jobs must be a positive integer: $JOBS" ;;
esac
[ "$JOBS" -gt 0 ] || die "jobs must be greater than zero"

validate_lock
verify_sdl2_patch
echo "Dependency lock valid: $LOCK_FILE"
echo "SDL2 UIKit patch verified: $SDL2_PATCH_FILE"

if [ "$MODE" = verify ]; then
    for id in sdl2 openal-soft ffmpeg; do
        archive="$DOWNLOAD_ROOT/$(dep_field "$id" 3)"
        if [ -f "$archive" ]; then
            verify_archive "$id" "$archive" "$(dep_field "$id" 4)"
            echo "Cached archive verified: $archive"
        else
            echo "Cached archive not present (not downloaded): $archive"
        fi
    done
    exit 0
fi

for id in sdl2 openal-soft ffmpeg; do
    fetch_dependency "$id"
done

if [ "$MODE" = download ]; then
    echo "Pinned archives downloaded and verified under $DOWNLOAD_ROOT"
    exit 0
fi

need_tool cmake
need_tool ninja
need_tool make
need_tool xcrun
need_tool xcodebuild
need_tool lipo

# Prevent caller and host package-manager paths from leaking into target
# detection. Homebrew CMake/Ninja may be used as host tools; their libraries may
# not be used as target inputs.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
unset LIBRARY_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR SDKROOT
export ZERO_AR_DATE=1

for id in sdl2 openal-soft ffmpeg; do
    extract_dependency "$id"
done

build_sdl2() {
    local platform prefix build_dir log_dir source_dir
    platform=$1
    prefix=$2
    build_dir=$3
    log_dir=$4
    source_dir="$SOURCE_ROOT/$(source_directory_name sdl2)"

    run_logged "SDL2 configure ($platform)" "$log_dir/sdl2-configure.log" \
        cmake -S "$source_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
        -DCMAKE_C_FLAGS=-DGLES_SILENCE_DEPRECATION \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_STATIC_PIC=ON \
        -DSDL_TEST=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_INSTALL_TESTS=OFF \
        -DSDL2_DISABLE_SDL2MAIN=ON \
        -DSDL2_DISABLE_UNINSTALL=ON \
        -DSDL2_DISABLE_INSTALL=OFF
    run_logged "SDL2 build ($platform)" "$log_dir/sdl2-build.log" \
        cmake --build "$build_dir" --parallel "$JOBS"
    run_logged "SDL2 install ($platform)" "$log_dir/sdl2-install.log" \
        cmake --install "$build_dir"
}

build_openal() {
    local platform prefix build_dir log_dir source_dir
    platform=$1
    prefix=$2
    build_dir=$3
    log_dir=$4
    source_dir="$SOURCE_ROOT/$(source_directory_name openal-soft)"

    run_logged "OpenAL Soft configure ($platform)" "$log_dir/openal-configure.log" \
        cmake -S "$source_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
        -DHAVE_WFUNCTION_EFFECTS=OFF \
        -DLIBTYPE=STATIC \
        -DALSOFT_UTILS=OFF \
        -DALSOFT_EXAMPLES=OFF \
        -DALSOFT_TESTS=OFF \
        -DALSOFT_INSTALL=ON \
        -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF \
        -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
        -DALSOFT_INSTALL_EXAMPLES=OFF \
        -DALSOFT_INSTALL_UTILS=OFF \
        -DALSOFT_UPDATE_BUILD_VERSION=OFF \
        -DALSOFT_ENABLE_MODULES=OFF \
        -DALSOFT_EMBED_HRTF_DATA=OFF \
        -DALSOFT_DLOPEN=OFF \
        -DALSOFT_RTKIT=OFF \
        -DALSOFT_BACKEND_COREAUDIO=ON \
        -DALSOFT_REQUIRE_COREAUDIO=ON \
        -DALSOFT_BACKEND_PIPEWIRE=OFF \
        -DALSOFT_BACKEND_PULSEAUDIO=OFF \
        -DALSOFT_BACKEND_ALSA=OFF \
        -DALSOFT_BACKEND_OSS=OFF \
        -DALSOFT_BACKEND_SOLARIS=OFF \
        -DALSOFT_BACKEND_SNDIO=OFF \
        -DALSOFT_BACKEND_JACK=OFF \
        -DALSOFT_BACKEND_OBOE=OFF \
        -DALSOFT_BACKEND_OPENSL=OFF \
        -DALSOFT_BACKEND_PORTAUDIO=OFF \
        -DALSOFT_BACKEND_SDL3=OFF \
        -DALSOFT_BACKEND_SDL2=OFF \
        -DALSOFT_BACKEND_WAVE=OFF
    run_logged "OpenAL Soft build ($platform)" "$log_dir/openal-build.log" \
        cmake --build "$build_dir" --parallel "$JOBS"
    run_logged "OpenAL Soft install ($platform)" "$log_dir/openal-install.log" \
        cmake --install "$build_dir"
}

build_ffmpeg() {
    local platform prefix build_dir log_dir target sdkroot source_dir
    local cc ar ranlib strip nm config_components config
    platform=$1
    prefix=$2
    build_dir=$3
    log_dir=$4
    target=$5
    sdkroot=$6
    source_dir="$SOURCE_ROOT/$(source_directory_name ffmpeg)"
    cc=$(xcrun --sdk "$platform" --find clang)
    ar=$(xcrun --sdk "$platform" --find ar)
    ranlib=$(xcrun --sdk "$platform" --find ranlib)
    strip=$(xcrun --sdk "$platform" --find strip)
    nm=$(xcrun --sdk "$platform" --find nm)

    run_logged_in_dir "FFmpeg configure ($platform)" "$log_dir/ffmpeg-configure.log" "$build_dir" \
        "$source_dir/configure" \
        --prefix="$prefix" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=arm64 \
        --sysroot="$sdkroot" \
        --cc="$cc" \
        --ar="$ar" \
        --ranlib="$ranlib" \
        --strip="$strip" \
        --nm="$nm" \
        --pkg-config=/usr/bin/false \
        --extra-cflags="-target $target -arch arm64 -fPIC" \
        --extra-ldflags="-target $target -arch arm64" \
        --disable-shared \
        --enable-static \
        --enable-pic \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-network \
        --disable-autodetect \
        --disable-everything \
        --disable-avdevice \
        --disable-avfilter \
        --disable-runtime-cpudetect \
        --disable-dotprod \
        --disable-i8mm \
        --disable-sve \
        --disable-sve2 \
        --disable-sme \
        --disable-sme-i16i64 \
        --disable-sme2 \
        --enable-small \
        --enable-pthreads \
        --enable-avcodec \
        --enable-avformat \
        --enable-avutil \
        --enable-swresample \
        --enable-swscale \
        --enable-decoder=mdec \
        --enable-decoder=adpcm_xa \
        --enable-demuxer=str
    run_logged "FFmpeg build ($platform)" "$log_dir/ffmpeg-build.log" \
        make -C "$build_dir" -j "$JOBS"
    run_logged "FFmpeg install ($platform)" "$log_dir/ffmpeg-install.log" \
        make -C "$build_dir" install-libs install-headers

    config_components="$build_dir/config_components.h"
    config="$build_dir/config.h"
    grep -q '^#define CONFIG_MDEC_DECODER 1$' "$config_components" ||
        die "FFmpeg $platform build is missing the MDEC decoder"
    grep -q '^#define CONFIG_ADPCM_XA_DECODER 1$' "$config_components" ||
        die "FFmpeg $platform build is missing the ADPCM_XA decoder"
    grep -q '^#define CONFIG_STR_DEMUXER 1$' "$config_components" ||
        die "FFmpeg $platform build is missing the PlayStation STR demuxer"
    grep -q '^#define CONFIG_AVDEVICE 0$' "$config" ||
        die "FFmpeg $platform unexpectedly enabled libavdevice"
    grep -q '^#define CONFIG_AVFILTER 0$' "$config" ||
        die "FFmpeg $platform unexpectedly enabled libavfilter"
}

write_smoke_source() {
    local source_file
    source_file=$1
    cat >"$source_file" <<'EOF'
#define SDL_MAIN_HANDLED 1
#include <SDL2/SDL.h>
#include <AL/alc.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

int main() {
    SDL_version version{};
    SDL_GetVersion(&version);
    ALCdevice *device = alcOpenDevice(nullptr);
    if (device != nullptr) alcCloseDevice(device);
    const AVCodec *mdec = avcodec_find_decoder(AV_CODEC_ID_MDEC);
    const AVCodec *xa = avcodec_find_decoder(AV_CODEC_ID_ADPCM_XA);
    const AVInputFormat *str = av_find_input_format("str");
    return (mdec && xa && str && swr_get_class() && sws_get_class()) ? 0 : 1;
}
EOF
}

validate_and_link() {
    local platform prefix smoke_dir log_dir target sdkroot expected_libs
    local library path archive_members symbols source_file executable cxx
    local expected_platform
    platform=$1
    prefix=$2
    smoke_dir=$3
    log_dir=$4
    target=$5
    sdkroot=$6

    expected_libs='libSDL2.a libopenal.a libavformat.a libavcodec.a libswresample.a libswscale.a libavutil.a'
    for library in $expected_libs; do
        path="$prefix/lib/$library"
        [ -f "$path" ] || die "missing $platform static library: $path"
        lipo -verify_arch arm64 "$path" >/dev/null 2>&1 ||
            die "$path does not contain arm64"
    done
    if find "$prefix" -type f \( -name '*.dylib' -o -name '*.so' \) | grep -q .; then
        die "$platform prefix unexpectedly contains a shared library"
    fi

    archive_members="$TMPDIR/sf1-ios-deps-members.$$.txt"
    xcrun ar -t "$prefix/lib/libSDL2.a" >"$archive_members"
    grep -q 'SDL_mfijoystick.m.o' "$archive_members" ||
        die "SDL2 $platform archive is missing the MFi/GameController backend"
    xcrun ar -t "$prefix/lib/libopenal.a" >"$archive_members"
    grep -q 'coreaudio.cpp.o' "$archive_members" ||
        die "OpenAL Soft $platform archive is missing CoreAudio"
    rm -f -- "$archive_members"

    symbols="$TMPDIR/sf1-ios-deps-symbols.$$.txt"
    xcrun nm -gU "$prefix/lib/libSDL2.a" >"$symbols"
    grep -q '_SDL_UIKitRunApp$' "$symbols" ||
        die "SDL2 UIKit run-loop symbol missing for $platform"
    grep -q '_OBJC_CLASS_\$_SDLUIKitSceneDelegate$' "$symbols" ||
        die "SDL2 UIKit scene delegate class missing for $platform"
    grep -q '_UIKit_GetInterfaceOrientation$' "$symbols" ||
        die "SDL2 UIKit scene orientation symbol missing for $platform"
    xcrun nm -gU "$prefix/lib/libavcodec.a" >"$symbols"
    grep -q '_ff_mdec_decoder$' "$symbols" || die "MDEC symbol missing for $platform"
    grep -q '_ff_adpcm_xa_decoder$' "$symbols" || die "ADPCM_XA symbol missing for $platform"
    xcrun nm -gU "$prefix/lib/libavformat.a" >"$symbols"
    grep -q '_ff_str_demuxer$' "$symbols" || die "STR demuxer symbol missing for $platform"
    rm -f -- "$symbols"

    if grep -R -E '/opt/homebrew|/usr/local/(Cellar|opt|lib|include)' \
        "$prefix/lib/cmake" "$prefix/lib/pkgconfig" >"$log_dir/host-path-scan.log" 2>&1; then
        die "$platform package metadata contains a Homebrew or /usr/local target path"
    fi

    mkdir -p "$smoke_dir"
    source_file="$smoke_dir/deps-smoke.cpp"
    executable="$smoke_dir/deps-smoke"
    write_smoke_source "$source_file"
    cxx=$(xcrun --sdk "$platform" --find clang++)
    run_logged "dependency link smoke ($platform)" "$log_dir/link-smoke.log" \
        "$cxx" -target "$target" -isysroot "$sdkroot" \
        -I"$prefix/include" "$source_file" -L"$prefix/lib" \
        -lSDL2 -lopenal -lavformat -lavcodec -lswresample -lswscale -lavutil \
        -framework CoreVideo -framework CoreAudio -framework AudioToolbox \
        -framework AVFoundation -framework CoreBluetooth -framework CoreGraphics \
        -framework CoreMotion -framework Foundation -framework GameController \
        -framework Metal -framework OpenGLES -framework QuartzCore -framework UIKit \
        -framework CoreHaptics -framework CoreFoundation -lm -lpthread \
        -o "$executable"

    {
        file "$executable"
        lipo -info "$executable"
        xcrun vtool -show-build "$executable"
        xcrun otool -L "$executable"
    } >"$log_dir/link-smoke-metadata.log"
    if grep -E '/opt/homebrew|/usr/local/(Cellar|opt|lib)' \
        "$log_dir/link-smoke-metadata.log" >/dev/null; then
        die "$platform smoke executable links a host package-manager library"
    fi

    expected_platform=IOS
    [ "$platform" = iphonesimulator ] && expected_platform=IOSSIMULATOR
    grep -q "platform $expected_platform" "$log_dir/link-smoke-metadata.log" ||
        die "$platform smoke executable has the wrong Mach-O platform"
    echo "Validated $platform arm64 static dependency prefix: $prefix"
}

build_platform() {
    local platform target sdkroot sdkversion manifest_sha script_sha xcode_version key
    local platform_build prefix log_dir smoke_dir build_stamp install_stamp path
    platform=$1
    case "$platform" in
        iphoneos) target="arm64-apple-ios$DEPLOYMENT_TARGET" ;;
        iphonesimulator) target="arm64-apple-ios$DEPLOYMENT_TARGET-simulator" ;;
        *) die "internal platform error: $platform" ;;
    esac

    sdkroot=$(xcrun --sdk "$platform" --show-sdk-path)
    sdkversion=$(xcrun --sdk "$platform" --show-sdk-version)
    manifest_sha=$(sha256_file "$LOCK_FILE")
    script_sha=$(sha256_file "$SCRIPT_DIR/build-ios-deps.sh")
    xcode_version=$(xcodebuild -version | tr '\n' ' ')
    key=$(printf '%s\n' \
        "$RECIPE_VERSION|$manifest_sha|$script_sha|$SDL2_PATCH_SHA256|$platform|$sdkversion|$DEPLOYMENT_TARGET|$xcode_version" |
        sha256_text)

    platform_build="$BUILD_ROOT/$platform"
    prefix="$INSTALL_ROOT/$platform"
    log_dir="$LOG_ROOT/$platform"
    smoke_dir="$SMOKE_ROOT/$platform"
    build_stamp="$platform_build/.sf1-ios-deps-key"
    install_stamp="$prefix/.sf1-ios-deps-key"

    if [ "$CLEAN" -eq 1 ]; then
        for path in "$platform_build" "$prefix" "$log_dir" "$smoke_dir"; do
            [ ! -e "$path" ] || safe_remove_tree "$path"
        done
    fi
    if [ ! -f "$build_stamp" ] || [ "$(cat "$build_stamp" 2>/dev/null || true)" != "$key" ]; then
        [ ! -e "$platform_build" ] || safe_remove_tree "$platform_build"
    fi
    if [ ! -f "$install_stamp" ] || [ "$(cat "$install_stamp" 2>/dev/null || true)" != "$key" ]; then
        [ ! -e "$prefix" ] || safe_remove_tree "$prefix"
    fi

    mkdir -p "$platform_build/sdl2" "$platform_build/openal-soft" \
        "$platform_build/ffmpeg" "$prefix" "$log_dir" "$smoke_dir"

    build_sdl2 "$platform" "$prefix" "$platform_build/sdl2" "$log_dir"
    build_openal "$platform" "$prefix" "$platform_build/openal-soft" "$log_dir"
    build_ffmpeg "$platform" "$prefix" "$platform_build/ffmpeg" "$log_dir" \
        "$target" "$sdkroot"
    validate_and_link "$platform" "$prefix" "$smoke_dir" "$log_dir" \
        "$target" "$sdkroot"

    printf '%s\n' "$key" >"$build_stamp"
    printf '%s\n' "$key" >"$install_stamp"
}

case "$PLATFORM" in
    iphoneos) build_platform iphoneos ;;
    iphonesimulator) build_platform iphonesimulator ;;
    all)
        build_platform iphonesimulator
        build_platform iphoneos
        ;;
esac

echo "iOS dependency bootstrap complete under $INSTALL_ROOT"
