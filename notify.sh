#!/bin/bash
# Claude Code notification script (macOS only: uses lsappinfo, afplay, osascript, md5;
# optional yabai for Warp window titles).
# - Detects source app (Warp, WebStorm, VS Code, etc.) from env vars
# - Custom icon via ClaudeCodeNotifier.app
# - Suppresses when user is focused on the source app
# - Click activates the correct app
# - Per-(app, directory) suppress keys so multiple sessions don't interfere
# - Stop events: body is a CC-style verb + turn duration ("Wrangled for 3m 5s")

BUNDLE_ID="${__CFBundleIdentifier:-}"

# Suppress key — (app, directory) pair so sessions in different apps/repos don't collide.
SUPPRESS_KEY=$(echo -n "${BUNDLE_ID}-${PWD}" | md5)
SUPPRESS_DIR="/tmp/claude-notify-suppress-${SUPPRESS_KEY}"

# --clear: called by UserPromptSubmit so the next Notification fires. Scoped to THIS
# session's key — other idle sessions stay suppressed until their own prompt submits.
if [ "$1" = "--clear" ]; then
    rmdir "$SUPPRESS_DIR" 2>/dev/null
    exit 0
fi

# ------------------------------------------------------------------------------
# Transcript helpers
# ------------------------------------------------------------------------------

# Pretty-print seconds: 57 → "57s", 185 → "3m 5s", 4261 → "1h 11m"
format_duration() {
    local s=$1
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        printf '%dm %ds' $((s / 60)) $((s % 60))
    else
        printf '%dh %dm' $((s / 3600)) $(((s % 3600) / 60))
    fi
}

# Turn wall-clock: seconds between the last real user prompt and now (Stop fires
# at turn end, so `now` IS the end — reading the final assistant timestamp from
# the transcript races the CLI's flush and under-counts when it loses).
# Real user prompts carry `permissionMode`; slash-commands, caveats, tool_results
# and injected context do not — so that field cleanly separates them.
turn_duration_seconds() {
    local transcript="$1"
    [ -f "$transcript" ] || return 1
    local prompt_s
    prompt_s=$(jq -sr '
        def iso: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
        [.[] | select(.type == "user" and .permissionMode and .timestamp) | .timestamp]
        | if length == 0 then empty else (last | iso) end
    ' "$transcript" 2>/dev/null)
    [ -z "$prompt_s" ] && return 1
    local diff=$(( $(date +%s) - prompt_s ))
    [ "$diff" -gt 0 ] || return 1
    echo "$diff"
}

# CC-style past-tense verb pool — picked at random on each Stop firing so the
# notification reads "Wrangled for 57s", "Pondered for 3m 5s", etc.
STOP_VERBS=(Crunched Wrangled Finagled Pondered Cooked Noodled Tinkered Brewed \
            Cogitated Mulled Percolated Ruminated Concocted Hustled Churned \
            Simmered Whipped Puttered Synthesized Contemplated Deliberated \
            Formulated Schemed Plotted)

random_stop_verb() {
    echo "${STOP_VERBS[$RANDOM % ${#STOP_VERBS[@]}]}"
}

# Escape for an osascript double-quoted string literal (fallback notifier path).
osa_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ------------------------------------------------------------------------------
# Main flow
# ------------------------------------------------------------------------------

# Detect source app
case "$TERM_PROGRAM" in
    WarpTerminal)   APP_NAME="Warp" ;;
    vscode)         APP_NAME="VS Code" ;;
    Apple_Terminal) APP_NAME="Terminal" ;;
    iTerm.app)      APP_NAME="iTerm" ;;
    *)
        case "$BUNDLE_ID" in
            com.jetbrains.WebStorm*)    APP_NAME="WebStorm" ;;
            com.jetbrains.intellij*)    APP_NAME="IntelliJ" ;;
            com.jetbrains.pycharm*)     APP_NAME="PyCharm" ;;
            com.jetbrains.goland*)      APP_NAME="GoLand" ;;
            com.microsoft.VSCode*)      APP_NAME="VS Code" ;;
            *)                          APP_NAME="${TERM_PROGRAM:-Terminal}" ;;
        esac
        ;;
esac

# Get git repository name
repo_name=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$repo_root" ]; then
        repo_name=$(basename "$repo_root")
    fi
fi

# TTL cleanup, gated once-per-minute via stamp file so the hot path is cheap.
SWEEP_STAMP=/tmp/claude-notify-sweep
if [ ! -f "$SWEEP_STAMP" ] || [ -n "$(find "$SWEEP_STAMP" -mmin +1 2>/dev/null)" ]; then
    find -L /tmp -maxdepth 1 -type d -name 'claude-notify-suppress-*' -mmin +5 -exec rmdir {} \; 2>/dev/null
    touch "$SWEEP_STAMP"
fi

# Frontmost check — skip if user is focused on the source app.
frontmost=$(lsappinfo info -only bundleID "$(lsappinfo front 2>/dev/null)" 2>/dev/null | awk -F'"' '{print $4}')
if [ -z "$frontmost" ]; then
    frontmost=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
fi
# Require non-empty BUNDLE_ID so empty-vs-empty can't silently suppress when
# invoked outside a GUI app (cron, manual CLI, etc.).
if [ -n "$BUNDLE_ID" ] && [ "$frontmost" = "$BUNDLE_ID" ]; then
    exit 0
fi

# Atomic dedup — first firing wins; duplicate Stop/Notification exits silently.
if ! mkdir "$SUPPRESS_DIR" 2>/dev/null; then
    exit 0
fi

# Slurp hook JSON once, past the early-exit gate so only real firings pay for jq.
payload=""
hook_event=""
transcript_path=""
stdin_message=""
if [ ! -t 0 ]; then
    payload=$(cat)
fi
if [ -n "$payload" ]; then
    hook_event=$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)
    transcript_path=$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)
    stdin_message=$(jq -r '.message // ""' <<<"$payload" 2>/dev/null)
fi

# For Stop, derive turn duration from the transcript.
dur_formatted=""
if [ "$hook_event" = "Stop" ] && [ -n "$transcript_path" ]; then
    _dur=$(turn_duration_seconds "$transcript_path")
    if [ -n "$_dur" ] && [ "$_dur" -gt 0 ] 2>/dev/null; then
        dur_formatted=$(format_duration "$_dur")
    fi
fi

# Build context (Warp window title via yabai → repo name → empty)
context=""
if [ "$APP_NAME" = "Warp" ] && command -v yabai &>/dev/null; then
    warp_pid=""
    p=$$
    # Depth 5 is plenty: notify.sh → claude → shell → Warp is ~4 levels.
    for _ in 1 2 3 4 5; do
        [ -z "$p" ] || [ "$p" -le 1 ] && break
        if ps -p "$p" -o command= 2>/dev/null | grep -q 'Warp\.app'; then
            warp_pid=$p
            break
        fi
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
    win_title=$(yabai -m query --windows 2>/dev/null | jq -r --arg wp "${warp_pid:-0}" '
        ([.[] | select(.app == "Warp" and ."has-focus" == true)][0]
         // [.[] | select(.pid == ($wp | tonumber))][0]
         // [.[] | select(.app == "Warp")][0]
        ) | (.title // "")')
    if [ -n "$win_title" ]; then
        context=$(echo "$win_title" | sed 's/^[^a-zA-Z0-9]*//')
    fi
fi
if [ -z "$context" ] && [ -n "$repo_name" ]; then
    context="$repo_name"
fi

# Subtitle: "App — context" (duration lives in the body now)
if [ -n "$context" ]; then
    subtitle="${APP_NAME} — ${context}"
else
    subtitle="$APP_NAME"
fi

# Resolve message:
#   1. explicit $1 (manual invocation / legacy settings.json)
#   2. Stop → "<random verb> for <duration>", "Ready" if no duration
#   3. Notification's .message from the JSON payload
#   4. generic default
if [ -n "$1" ]; then
    message="$1"
elif [ "$hook_event" = "Stop" ]; then
    if [ -n "$dur_formatted" ]; then
        message="$(random_stop_verb) for $dur_formatted"
    else
        message="Ready"
    fi
elif [ -n "$stdin_message" ]; then
    message="$stdin_message"
else
    message="Claude Code needs your attention"
fi

SOUND="$2"

# Send notification — click activates the source app
NOTIFIER=~/.claude/ClaudeCodeNotifier.app/Contents/MacOS/terminal-notifier
if [ -x "$NOTIFIER" ]; then
    args=(-title "Claude Code" -subtitle "$subtitle" -message "$message")
    if [ -n "$BUNDLE_ID" ]; then
        args+=(-activate "$BUNDLE_ID")
    fi
    "$NOTIFIER" "${args[@]}"
else
    osascript -e "display notification \"$(osa_escape "$message")\" with title \"Claude Code\" subtitle \"$(osa_escape "$subtitle")\""
fi

# Play sound only on real firings — frontmost/dedup exits above skip this naturally
if [ -n "$SOUND" ] && [ -f "$SOUND" ]; then
    afplay "$SOUND" &
fi
