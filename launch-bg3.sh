#!/bin/bash
# BG3MacZoom launcher for macOS (Apple Silicon).
#
# Launches Baldur's Gate 3 with bg3zoom.dylib injected. On first run it downloads the
# prebuilt dylib from the GitHub release (no build tools needed); if that fails it builds
# from source (needs the Xcode Command Line Tools: xcode-select --install).
#
# Requirements: the Steam client running (logged in).
#
# Usage:
#   ./launch-bg3.sh                    # settings come from config.toml
#   BG3_ZOOM_MAX=40 ./launch-bg3.sh    # one-off max-zoom override
#   BG3_APP="/path/Baldur's Gate 3.app" ./launch-bg3.sh   # non-standard install path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYLIB="$SCRIPT_DIR/build/bg3zoom.dylib"
RELEASE_DYLIB_URL="https://github.com/IndyIndyIndy/BG3MacZoom/releases/latest/download/bg3zoom.dylib"

# Locate the BG3 app bundle: explicit override, common paths, then Steam libraries.
find_bg3() {
    if [[ -n "${BG3_APP:-}" ]]; then echo "$BG3_APP"; return; fi
    local candidates=(
        "$HOME/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
        "/Applications/Baldur's Gate 3.app"
        "$HOME/Applications/Baldur's Gate 3.app"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -d "$c" ]] && { echo "$c"; return; }
    done
    local vdf="$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf" ]]; then
        local path
        while IFS= read -r path; do
            c="$path/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
            [[ -d "$c" ]] && { echo "$c"; return; }
        done < <(grep -oE '"/[^"]+"' "$vdf" | tr -d '"')
    fi
    echo ""
}

BG3_APP_RESOLVED="$(find_bg3)"
if [[ -z "$BG3_APP_RESOLVED" ]]; then
    echo "error: Baldur's Gate 3.app not found." >&2
    echo "Set the path manually: BG3_APP=\"/path/Baldur's Gate 3.app\" ./launch-bg3.sh" >&2
    exit 1
fi
BG3_BIN="$BG3_APP_RESOLVED/Contents/MacOS/Baldur's Gate 3"
if [[ ! -x "$BG3_BIN" ]]; then
    echo "error: BG3 binary not executable: $BG3_BIN" >&2
    exit 1
fi

# Obtain the dylib on first run: prefer the prebuilt release asset (no build tools
# needed; curl sets no quarantine), fall back to building from source.
if [[ ! -f "$DYLIB" ]]; then
    mkdir -p "$SCRIPT_DIR/build"
    if curl -fsSL "$RELEASE_DYLIB_URL" -o "$DYLIB" 2>/dev/null \
        && file "$DYLIB" 2>/dev/null | grep -q 'arm64'; then
        codesign -s - -f "$DYLIB" 2>/dev/null || true
        echo "Downloaded prebuilt bg3zoom.dylib."
    elif xcode-select -p >/dev/null 2>&1; then
        rm -f "$DYLIB"
        echo "Building bg3zoom.dylib from source..."
        xcrun clang++ -arch arm64 -std=c++17 -O2 -Wall -fobjc-arc -dynamiclib \
            -framework Foundation \
            -o "$DYLIB" "$SCRIPT_DIR/src/bg3zoom.mm" "$SCRIPT_DIR/src/config.cpp"
        codesign -s - -f "$DYLIB"
    else
        rm -f "$DYLIB"
        echo "error: couldn't download the prebuilt dylib, and no build tools are available." >&2
        echo "Connect to the internet and retry, or install the tools: xcode-select --install" >&2
        exit 1
    fi
fi

export DYLD_INSERT_LIBRARIES="$DYLIB"

# Steam builds need SteamAppId so Steamworks initialises without a Steam launch.
# The GOG build is DRM-free and launches directly, so only set it for Steam installs.
if [[ "$BG3_APP_RESOLVED" == *"/steamapps/"* ]]; then
    export SteamAppId=1086940
    export SteamGameId=1086940
fi

echo "Launching Baldur's Gate 3 with bg3zoom.dylib"
echo "  App: $BG3_APP_RESOLVED"
echo "  Log: ~/Library/Logs/BG3MacZoom.log"

cd "$BG3_APP_RESOLVED/Contents/MacOS"
exec "$BG3_BIN"
