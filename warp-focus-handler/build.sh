#!/bin/bash
# Builds ClaudeFocusHandler.app: an AppleScript applet that registers the
# `claude-focus://` URL scheme and routes focus/activate requests to Warp.
# Output: ./build/ClaudeFocusHandler.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
SRC="${SCRIPT_DIR}/main.applescript"
OVERLAY="${SCRIPT_DIR}/Info.plist"
OUT="${BUILD_DIR}/ClaudeFocusHandler.app"

if [ ! -f "$SRC" ]; then
	echo "Error: ${SRC} not found" >&2
	exit 1
fi
if [ ! -f "$OVERLAY" ]; then
	echo "Error: ${OVERLAY} not found" >&2
	exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$OUT"

osacompile -o "$OUT" "$SRC"

target_plist="${OUT}/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy

# Overlay the URL scheme registration. Delete first so Merge re-adds the value
# we want rather than leaving any pre-existing entry in place (PlistBuddy's
# Merge is a no-op when the target key already exists).
"$PB" -c "Delete :CFBundleURLTypes" "$target_plist" >/dev/null 2>&1 || true
"$PB" -c "Merge ${OVERLAY} :" "$target_plist" >/dev/null

echo "Built: ${OUT}"
