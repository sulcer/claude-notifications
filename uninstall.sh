#!/bin/bash
# Removes only the hook entries that invoke ~/.claude/notify.sh.
# Leaves user-added hooks, notify.sh, and the .app bundle intact.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"

if ! command -v jq >/dev/null 2>&1; then
	echo "Error: jq is required. Install with: brew install jq" >&2
	exit 1
fi

if [ ! -f "$SETTINGS" ]; then
	echo "No settings.json at $SETTINGS — nothing to do."
	exit 0
fi

ts=$(date +%s)
cp "$SETTINGS" "${SETTINGS}.bak.${ts}"
echo "Backed up settings.json → ${SETTINGS}.bak.${ts}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Remove any hook entry whose inner hooks reference ~/.claude/notify.sh.
# If an event's array empties out, drop the event key too.
jq '
	def is_ours($h): ($h.command // "") | test("(^|[^[:alnum:]])~/\\.claude/notify\\.sh([[:space:]]|$)");
	.hooks = (
		(.hooks // {})
		| to_entries
		| map(
			.value = (
				.value
				| map(
					.hooks = ((.hooks // []) | map(select(is_ours(.) | not)))
				)
				| map(select((.hooks // []) | length > 0))
			)
		)
		| map(select((.value | length) > 0))
		| from_entries
	)
	| if (.hooks == {}) then del(.hooks) else . end
' "$SETTINGS" > "$tmp"

mv "$tmp" "$SETTINGS"
trap - EXIT

echo "Removed Claude Notifications hook entries from ${SETTINGS}"
echo
echo "notify.sh and ClaudeCodeNotifier.app were left in place in case other tooling uses them."
echo "To remove them manually:"
echo "  rm -f ${CLAUDE_DIR}/notify.sh"
echo "  rm -rf ${CLAUDE_DIR}/ClaudeCodeNotifier.app"
