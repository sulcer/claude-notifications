# Warp Focus Handler

A tiny AppleScript applet that registers the `claude-focus://` URL scheme and routes it to [Warp](https://www.warp.dev/). Lets you click a link anywhere on macOS and land on a specific Warp tab.

Warp-specific — the applet drives Warp's Navigation Palette via UI scripting, which other terminals don't expose.

## URL format

| URL | Action |
| --- | --- |
| `claude-focus://activate` | Bring Warp to the front (no tab switching) |
| `claude-focus://focus/<id>` | Bring Warp forward, then search for a tab via Navigation Palette. The search term is read from `/tmp/claude-focus-<id>.txt` (which the caller writes, and the applet deletes after reading) |

The two-file handshake for `focus` exists because URL schemes don't play nicely with arbitrary strings (spaces, slashes, unicode) — the `<id>` is just a short token pointing at a temp file holding the real search term.

## Build

```bash
./build.sh
```

Produces `build/ClaudeFocusHandler.app`. The script runs `osacompile` on `main.applescript`, then overlays `Info.plist` onto the bundle to register the URL scheme.

## Install

```bash
cp -R build/ClaudeFocusHandler.app /Applications/
open /Applications/ClaudeFocusHandler.app
```

Opening it once lets macOS register the `claude-focus://` handler with Launch Services. Grant permissions when prompted:

- **Accessibility** — needed to click the Navigation Palette menu item
- **Automation → Warp** and **Automation → System Events** — needed to `tell` those apps

System Settings → Privacy & Security has toggles for each.

## Test

```bash
open "claude-focus://activate"
```

Warp should come to the front. For the search flow:

```bash
echo "my-tab-title" > /tmp/claude-focus-test.txt
open "claude-focus://focus/test"
```

Warp comes forward, Navigation Palette opens, "my-tab-title" is typed in, Enter fires.

## Troubleshooting

- **Nothing happens on `open "claude-focus://…"`** — macOS hasn't registered the handler. Re-open `ClaudeFocusHandler.app` manually from Finder.
- **Warp activates but Navigation Palette doesn't open** — Accessibility permission missing. Re-check System Settings.
- **Process name mismatch** — the applet targets `process "stable"` (Warp's internal process name on the stable channel). If you're on Warp Preview, edit `main.applescript` and rebuild.
