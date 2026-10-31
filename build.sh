#!/bin/bash
# RG Lander: build script
#
#   ./build.sh             build everything below into dist/
#   ./build.sh muos        muOS package       -> dist/RGLander_vX.Y.Z.muxapp
#   ./build.sh portmaster  PortMaster package -> dist/rglander_vX.Y.Z_portmaster.zip
#   ./build.sh love        game only          -> dist/rglander.love
#   ./build.sh test [N]    headless autopilot self-test, N sorties per world
#   ./build.sh run [args]  run the game on this PC (needs LÖVE 11.x)
#
# The muxapp bundles an aarch64 LÖVE 11.5 runtime (bin/love + bin/libs.aarch64),
# as rgTrek does. By default it is taken from the 2048 Plus project (MIT
# licensed, proven on muOS H700 devices) at a pinned tag. To use your own
# runtime, set LOVE_RUNTIME=/path/to/dir containing love and libs.aarch64/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rglander"
MUX_NAME="RGLander"
RUNTIME_REPO="https://github.com/saitamasahil/2048plus.git"
RUNTIME_TAG="v7.0.1"
GAME_FILES=(main.lua conf.lua src)

VERSION="$(sed -n 's/^ *VERSION = "\([0-9.]*\)",$/\1/p' "$ROOT/src/core.lua")"
[ -n "$VERSION" ] || { echo "Could not read VERSION from src/core.lua" >&2; exit 1; }

fetch_runtime() {
    RUNTIME_LICENSES=""
    if [ -n "${LOVE_RUNTIME:-}" ]; then
        [ -x "$LOVE_RUNTIME/love" ] && [ -d "$LOVE_RUNTIME/libs.aarch64" ] || {
            echo "LOVE_RUNTIME must contain 'love' and 'libs.aarch64/'" >&2; exit 1; }
        RUNTIME_DIR="$LOVE_RUNTIME"
        return
    fi
    local checkout="$CACHE/runtime-$RUNTIME_TAG"
    if [ ! -x "$checkout/bin/love" ]; then
        echo "Downloading aarch64 LÖVE runtime from 2048 Plus ($RUNTIME_TAG)..."
        rm -rf "$checkout"
        mkdir -p "$CACHE"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$RUNTIME_TAG" \
            --filter=blob:none --sparse "$RUNTIME_REPO" "$checkout"
        git -C "$checkout" sparse-checkout set bin licenses >/dev/null
    fi
    RUNTIME_DIR="$checkout/bin"
    RUNTIME_LICENSES="$checkout/licenses"
}

copy_game() {
    local dest="$1"
    mkdir -p "$dest"
    (cd "$ROOT" && tar --exclude='.DS_Store' -cf - "${GAME_FILES[@]}") | (cd "$dest" && tar -xf -)
}

build_love() {
    local stage="$DIST/love-stage"
    local out="$DIST/rglander.love"
    rm -rf "$stage" "$out"
    copy_game "$stage"
    (cd "$stage" && zip -qr -X "$out" .)
    rm -rf "$stage"
    echo "Built $(basename "$out")  (run with: love dist/rglander.love)"
}

build_portmaster() {
    local stage="$DIST/pm-stage"
    local out="$DIST/rglander_v${VERSION}_portmaster.zip"
    rm -rf "$stage" "$out"
    copy_game "$stage/rglander/gamedata"
    cp "$ROOT/LICENSE" "$stage/rglander/LICENSE"
    cp "$ROOT/port/RG Lander.sh" "$stage/"
    chmod +x "$stage/RG Lander.sh"
    (cd "$stage" && zip -qr -X "$out" "RG Lander.sh" rglander)
    rm -rf "$stage"
    echo "Built $(basename "$out")  (unzip into the SD card's ports/ folder)"
}

build_muos() {
    fetch_runtime
    local stage="$DIST/mux-stage"
    local app="$stage/$MUX_NAME"
    local out="$DIST/${MUX_NAME}_v${VERSION}.muxapp"
    rm -rf "$stage" "$out"
    mkdir -p "$app/glyph" "$app/.game/bin" "$app/.game/licenses"

    cp "$ROOT/muos/mux_launch.sh" "$ROOT/muos/mux_lang.ini" "$app/"
    cp "$ROOT/muos/glyph/rglander.svg" "$ROOT/muos/glyph/rglander.png" "$app/glyph/"
    copy_game "$app/.game"
    cp "$RUNTIME_DIR/love" "$app/.game/bin/"
    cp -R "$RUNTIME_DIR/libs.aarch64" "$app/.game/bin/"

    cp "$ROOT/LICENSE" "$app/.game/licenses/rglander.LICENSE"
    if [ -n "$RUNTIME_LICENSES" ] && [ -f "$RUNTIME_LICENSES/love.LICENSE" ]; then
        cp "$RUNTIME_LICENSES/love.LICENSE" "$app/.game/licenses/love.LICENSE"
        cp "$RUNTIME_LICENSES/2048plus.LICENSE" "$app/.game/licenses/runtime-from-2048plus.LICENSE" 2>/dev/null || true
    fi

    chmod +x "$app/mux_launch.sh" "$app/.game/bin/love"
    (cd "$stage" && zip -qr -X "$out" "$MUX_NAME")
    rm -rf "$stage"
    echo "Built $(basename "$out") ($(du -h "$out" | cut -f1))"
    echo "  Copy it to /mnt/mmc/MUOS/ARCHIVE/ and install with Applications > Archive Manager."
}

find_love() {
    if command -v love >/dev/null 2>&1; then
        echo love
    elif [ -x /Applications/love.app/Contents/MacOS/love ]; then
        echo /Applications/love.app/Contents/MacOS/love
    else
        echo "LÖVE 11.x not found. Install it from https://love2d.org" >&2
        return 1
    fi
}

mkdir -p "$DIST"
case "${1:-all}" in
    all) build_love; build_portmaster; build_muos ;;
    love) build_love ;;
    portmaster) build_portmaster ;;
    muos) build_muos ;;
    test) (cd "$ROOT" && "$(find_love)" . --autotest "${2:-40}") ;;
    run)
        shift
        LOVE_BIN="$(find_love)"
        cd "$ROOT" && "$LOVE_BIN" . "$@"
        ;;
    *) echo "Usage: ./build.sh [all|muos|portmaster|love|test|run]" >&2; exit 1 ;;
esac
