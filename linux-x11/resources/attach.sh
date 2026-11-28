#!/bin/bash
# TmuxManager console wrapper for Linux X11 + WezTerm.
# Usage: attach.sh <entry-uuid>
#
# Owns one WezTerm window for one configured entry: runs ssh + tmux, writes a
# state file so the app knows the window is alive, and reconnects on SIGUSR1.

set -u

ENTRY_ID="${1:-}"
if [ -z "$ENTRY_ID" ]; then
    echo "attach.sh: missing entry id" >&2
    exit 64
fi

if [ -n "${TMUX_MANAGER_DIR:-}" ]; then
    SUPPORT="$TMUX_MANAGER_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
    SUPPORT="$XDG_DATA_HOME/tmux-manager"
else
    SUPPORT="$HOME/.local/share/tmux-manager"
fi

ENV_FILE="$SUPPORT/env/$ENTRY_ID.sh"
STATE_FILE="$SUPPORT/state/$ENTRY_ID.json"
LOG_FILE="$SUPPORT/log.txt"

RESET_SEQ=$'\033[0m\033[?1l\033>\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l\033[?1015l\033[?2004l\033[?1049l\033[?25h'

SSH_PID=""
RECONNECT_REQUESTED=0
STARTED_AT=$(date +%s)

log() {
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$ENTRY_ID" "$*" >>"$LOG_FILE" 2>/dev/null || true
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt 1000000 ]; then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi
}

say() {
    printf '%s\n' "$*"
    log "$*"
}

json_string_or_null() {
    if [ -z "${1:-}" ]; then
        printf 'null'
    else
        local escaped="${1//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        printf '"%s"' "$escaped"
    fi
}

write_state() {
    local ssh_part tmp
    if [ -n "$SSH_PID" ]; then ssh_part="$SSH_PID"; else ssh_part=""; fi
    mkdir -p "$SUPPORT/state" 2>/dev/null || true
    tmp="$SUPPORT/state/.$ENTRY_ID.$$.tmp"
    printf '{"entry_id":%s,"wrapper_pid":%s,"ssh_pid":%s,"window_class":%s,"wezterm_pane_id":%s,"tty":%s,"started_at":%s}\n' \
        "$(json_string_or_null "$ENTRY_ID")" \
        "$$" \
        "$( [ -n "$ssh_part" ] && printf '%s' "$ssh_part" || printf 'null' )" \
        "$(json_string_or_null "${WINDOW_CLASS:-}")" \
        "$(json_string_or_null "${WEZTERM_PANE_ID:-}")" \
        "$(json_string_or_null "${TTY_NAME:-}")" \
        "$STARTED_AT" >"$tmp" 2>/dev/null && mv -f "$tmp" "$STATE_FILE" 2>/dev/null
}

remove_state() {
    # Only remove the file when it still describes this wrapper: a newer wrapper
    # for the same entry may already have replaced it.
    if [ -f "$STATE_FILE" ] && grep -q "\"wrapper_pid\":$$," "$STATE_FILE" 2>/dev/null; then
        rm -f "$STATE_FILE"
    fi
}

reset_terminal() {
    stty sane 2>/dev/null || true
    printf '%s' "$RESET_SEQ"
}

kill_ssh() {
    if [ -n "$SSH_PID" ]; then
        kill -9 "$SSH_PID" 2>/dev/null || true
        SSH_PID=""
    fi
}

on_usr1() {
    RECONNECT_REQUESTED=1
    kill_ssh
}

on_hup() {
    log "terminal hung up"
    kill_ssh
    remove_state
    exit 0
}

on_term() {
    log "terminated"
    kill_ssh
    remove_state
    exit 0
}

on_exit() {
    kill_ssh
    remove_state
}

trap on_usr1 USR1
trap on_hup HUP
trap on_term TERM
trap on_exit EXIT

has_tty() {
    (: </dev/tty >/dev/tty) 2>/dev/null
}

TTY_NAME=$(tty 2>/dev/null | sed 's|^/dev/||' || true)
WINDOW_CLASS="${TMUX_MANAGER_WINDOW_CLASS:-}"
WEZTERM_PANE_ID="${WEZTERM_PANE:-}"
SSH_BIN="${TMUX_MANAGER_SSH_BIN:-/usr/bin/ssh}"

log "wrapper start pid=$$ tty=${TTY_NAME:-none} class=${WINDOW_CLASS:-none} pane=${WEZTERM_PANE_ID:-none}"

while :; do
    if [ ! -r "$ENV_FILE" ]; then
        say "This entry is no longer configured. Closing."
        exit 0
    fi
    # shellcheck disable=SC1090
    if ! . "$ENV_FILE"; then
        say "Cannot read entry configuration. Closing."
        exit 0
    fi

    if ! [[ "$SESSION" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        say "Invalid tmux session name: $SESSION"
        exit 65
    fi

    SSH_OPTS=( -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o ConnectTimeout=10 )
    if [ "${#EXTRA_SSH_OPTS[@]}" -gt 0 ]; then
        SSH_OPTS+=( "${EXTRA_SSH_OPTS[@]}" )
    fi

    REMOTE_CMD="$(printf '%q' "$TMUX_PATH") new-session -A"
    if [ "${DETACH_OTHER_CLIENTS:-0}" = "1" ]; then
        REMOTE_CMD="$REMOTE_CMD -D"
    fi
    REMOTE_CMD="$REMOTE_CMD -s $(printf '%q' "$SESSION")"

    log "connect host=$HOST session=$SESSION cmd=$REMOTE_CMD"
    printf 'connecting to %s (tmux session %s)\n' "$HOST" "$SESSION"

    if has_tty; then
        "$SSH_BIN" -t "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD" </dev/tty >/dev/tty 2>&1 &
    else
        "$SSH_BIN" -t "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD" &
    fi
    SSH_PID=$!
    write_state

    RECONNECT_REQUESTED=0
    wait "$SSH_PID"
    RC=$?
    SSH_PID=""
    write_state
    reset_terminal

    if [ "$RECONNECT_REQUESTED" = "1" ]; then
        RECONNECT_REQUESTED=0
        log "reconnect requested by app"
        printf 'reconnecting...\n'
        continue
    fi

    case "$RC" in
        0)
            log "ssh exited 0 (detached or session ended)"
            exit 0
            ;;
        137|143)
            log "ssh exited $RC (killed) - reconnecting"
            printf 'reconnecting...\n'
            continue
            ;;
        *)
            log "ssh exited $RC"
            printf '\n'
            printf 'ssh exited with status %s.\n' "$RC"
            printf '[Enter] retry   [Ctrl-C] close window\n'
            while [ "${RECONNECT_REQUESTED}" = "0" ]; do
                if has_tty; then
                    if read -r -t 1 _ </dev/tty 2>/dev/null; then
                        break
                    fi
                else
                    sleep 1
                fi
            done
            continue
            ;;
    esac
done
