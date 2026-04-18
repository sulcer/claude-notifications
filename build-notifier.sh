#!/bin/bash
# Rebuilds ClaudeCodeNotifier.app from upstream terminal-notifier 2.0.0:
#   - downloads + SHA256-verifies the official release zip
#   - rebrands Info.plist (identifier, name, icon, LSUIElement)
#   - swaps in the Terminal.icns from icon/
# Output: ./build/ClaudeCodeNotifier.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ICON_SRC="${SCRIPT_DIR}/icon/Terminal.icns"

TN_VERSION="2.0.0"
TN_URL="https://github.com/julienXX/terminal-notifier/releases/download/${TN_VERSION}/terminal-notifier-${TN_VERSION}.zip"
TN_SHA256="316e767d979d12adb12c3538931b245108f8b1064af44087414c096cb3376d0c"

if [ ! -f "$ICON_SRC" ]; then
	echo "Error: icon not found at ${ICON_SRC}" >&2
	exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "${BUILD_DIR}/ClaudeCodeNotifier.app"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

zip_path="${tmpdir}/terminal-notifier-${TN_VERSION}.zip"

echo "Downloading terminal-notifier ${TN_VERSION}..."
curl -fsSL -o "$zip_path" "$TN_URL"

echo "Verifying SHA256..."
actual=$(shasum -a 256 "$zip_path" | awk '{print $1}')
if [ "$actual" != "$TN_SHA256" ]; then
	echo "SHA256 mismatch!" >&2
	echo "  expected: $TN_SHA256" >&2
	echo "  actual:   $actual" >&2
	exit 1
fi

echo "Unzipping..."
unzip -q "$zip_path" -d "$tmpdir"

# The release zip contains `terminal-notifier.app` at some depth — locate it.
src_app=$(find "$tmpdir" -maxdepth 4 -type d -name 'terminal-notifier.app' -print -quit)
if [ -z "$src_app" ]; then
	echo "Error: terminal-notifier.app not found inside release zip." >&2
	exit 1
fi

out_app="${BUILD_DIR}/ClaudeCodeNotifier.app"
cp -R "$src_app" "$out_app"

# Drop the upstream code signature — our mutations would invalidate it anyway.
rm -rf "${out_app}/Contents/_CodeSignature"

plist="${out_app}/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy

# Delete-then-Add is unconditionally correct: Set fails silently if the key
# is missing, and Add's quoting gets messy for values with spaces. This avoids
# both traps.
plist_reset() {
	local key="$1" type="$2" value="$3"
	"$PB" -c "Delete :${key}" "$plist" 2>/dev/null || true
	"$PB" -c "Add :${key} ${type} ${value}" "$plist"
}

plist_reset CFBundleIdentifier string "com.claude.code-notifier"
plist_reset CFBundleName        string "Claude Code"
plist_reset CFBundleIconFile    string "Terminal"
plist_reset LSUIElement         bool   "true"

# Swap icon. Remove any icon that shipped under a different name to avoid
# confusing LaunchServices.
rm -f "${out_app}/Contents/Resources/Terminal.icns"
cp "$ICON_SRC" "${out_app}/Contents/Resources/Terminal.icns"

echo "Built: ${out_app}"
