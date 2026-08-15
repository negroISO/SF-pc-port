#!/bin/sh

SF1_ROOT="/Volumes/iPhone/PS1_Rrecomps/SF1"

if [ ! -d "/Volumes/iPhone" ] || [ ! -d "$SF1_ROOT/.git" ]; then
    echo "SF1 external workspace is unavailable: $SF1_ROOT" >&2
    return 1 2>/dev/null || exit 1
fi

case "$PWD/" in
    "$SF1_ROOT/"|"$SF1_ROOT/"*) ;;
    *)
        echo "Run SF1 project commands from $SF1_ROOT" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

mkdir -p \
    "$SF1_ROOT/out/DerivedData" \
    "$SF1_ROOT/out/xcode-cache/CompilationCache.noindex" \
    "$SF1_ROOT/out/xcode-cache/ModuleCache.noindex" \
    "$SF1_ROOT/tmp/tool-tmp" \
    "$SF1_ROOT/tmp/xdg-cache" \
    "$SF1_ROOT/tmp/ccache" \
    "$SF1_ROOT/tmp/pip-cache" \
    "$SF1_ROOT/tmp/uv-cache"

export SF1_ROOT
export TMPDIR="$SF1_ROOT/tmp/tool-tmp/"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
export XDG_CACHE_HOME="$SF1_ROOT/tmp/xdg-cache"
export CLANG_MODULE_CACHE_PATH="$SF1_ROOT/out/xcode-cache/ModuleCache.noindex"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export CCACHE_DIR="$SF1_ROOT/tmp/ccache"
export PIP_CACHE_DIR="$SF1_ROOT/tmp/pip-cache"
export UV_CACHE_DIR="$SF1_ROOT/tmp/uv-cache"
export XCODE_DERIVED_DATA_PATH="$SF1_ROOT/out/DerivedData"

echo "SF1 external workspace active: $SF1_ROOT"
