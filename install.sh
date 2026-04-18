#!/bin/bash
# Installs the Claude Notifications hooks, notify.sh, and ClaudeCodeNotifier.app.
# Idempotent: safe to re-run. Backs up settings.json before mutating.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
EXAMPLE="${SCRIPT_DIR}/settings.example.json"
NOTIFY_SRC="${SCRIPT_DIR}/notify.sh"
NOTIFY_DST="${CLAUDE_DIR}/notify.sh"
APP_DST="${CLAUDE_DIR}/ClaudeCodeNotifier.app"

FORCE=0
for arg in "$@"; do
	case "$arg" in
		--force|-f) FORCE=1 ;;
		*) echo "Unknown arg: $arg" >&2; exit 2 ;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "Error: jq is required. Install with: brew install jq" >&2
	exit 1
fi

mkdir -p "$CLAUDE_DIR"

ts=$(date +%s)

# ---- notify.sh ----------------------------------------------------------------
if [ -e "$NOTIFY_DST" ]; then
	if ! cmp -s "$NOTIFY_SRC" "$NOTIFY_DST"; then
		if [ "$FORCE" -eq 1 ]; then
			cp "$NOTIFY_DST" "${NOTIFY_DST}.bak.${ts}"
			cp "$NOTIFY_SRC" "$NOTIFY_DST"
			chmod +x "$NOTIFY_DST"
			echo "Overwrote ${NOTIFY_DST} (backup: ${NOTIFY_DST}.bak.${ts})"
		else
			echo "Error: ${NOTIFY_DST} already exists and differs from ${NOTIFY_SRC}." >&2
			echo "Re-run with --force to overwrite (a backup will be created)." >&2
			exit 1
		fi
	else
		echo "notify.sh already up to date."
	fi
else
	cp "$NOTIFY_SRC" "$NOTIFY_DST"
	chmod +x "$NOTIFY_DST"
	echo "Installed ${NOTIFY_DST}"
fi

# ---- settings.json hooks merge ------------------------------------------------
if [ -f "$SETTINGS" ]; then
	cp "$SETTINGS" "${SETTINGS}.bak.${ts}"
	echo "Backed up settings.json → ${SETTINGS}.bak.${ts}"
else
	echo '{}' > "$SETTINGS"
fi

# Validate example is parseable before touching settings.
jq empty "$EXAMPLE"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Merge hook arrays without replacing existing entries; skip a new entry if any
# existing hook in the same event has a matching command string (idempotency).
jq --slurpfile ex "$EXAMPLE" '
	. as $cur
	| ($ex[0].hooks // {}) as $new
	| .hooks = (
		($cur.hooks // {}) as $have
		| reduce ($new | keys_unsorted[]) as $evt ($have;
			.[$evt] = (
				((.[$evt] // []) + ($new[$evt] // []))
				| . as $all
				| [ range(0; length) as $i
					| $all[$i] as $grp
					| ($grp.hooks // []) as $cmds
					| ($cmds | map(.command)) as $grp_cmds
					| if any(
						$all[0:$i][]?;
						((.hooks // []) | map(.command)) as $prior
						| any($grp_cmds[]; . as $c | $prior | index($c))
					) then empty else $grp end
				]
			)
		)
	)
' "$SETTINGS" > "$tmp"

mv "$tmp" "$SETTINGS"
trap - EXIT
echo "Merged hooks into ${SETTINGS}"

# ---- ClaudeCodeNotifier.app ---------------------------------------------------
if [ ! -d "$APP_DST" ]; then
	echo "Building ClaudeCodeNotifier.app..."
	if ( cd "$SCRIPT_DIR" && ./build-notifier.sh ); then
		if [ -d "${SCRIPT_DIR}/build/ClaudeCodeNotifier.app" ]; then
			mv "${SCRIPT_DIR}/build/ClaudeCodeNotifier.app" "$APP_DST"
			echo "Installed ${APP_DST}"
		else
			echo "Warning: build succeeded but build/ClaudeCodeNotifier.app not found; notify.sh will use osascript fallback." >&2
		fi
	else
		echo "Warning: build-notifier.sh failed; notify.sh will use osascript fallback." >&2
	fi
else
	echo "ClaudeCodeNotifier.app already present."
fi

echo
echo "Hooks installed. Restart Claude Code (or start a new session) to pick them up."
