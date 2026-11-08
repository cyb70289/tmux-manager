#!/bin/bash
# TmuxManager console wrapper.
# Usage: attach.sh <entry-uuid>
#
# Owns one iTerm2 window for one configured entry: runs ssh + tmux, writes a state
# file so the app knows the window is alive, and reconnects on demand.

set -u

ENTRY_ID="${1:-}"
if [ -z "$ENTRY_ID" ]; then
    echo "attach.sh: missing entry id" >&2
    exit 64
fi

SUPPORT="$HOME/Library/Application Support/TmuxManager"
ENV_FILE="$SUPPORT/env/$ENTRY_ID.sh"
STATE_FILE="$SUPPORT/state/$ENTRY_ID.json"
LOG_FILE="$SUPPORT/log.txt"

RESET_SEQ=$'\033[0m\033[?1l\033>\033[?1000l\033[?1002l\033[?1003l\033[?1004l\033[?1006l\033[?1015l\033[?2004l\033[?1049l\033[?25h'

SSH_PID=""
RECONNECT_REQUESTED=0
STARTED_AT=$(/bin/date +%s)

log() {
    printf '%s [%s] %s\n' "$(/bin/date -u +%FT%TZ)" "$ENTRY_ID" "$*" >>"$LOG_FILE" 2>/dev/null || true
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(/usr/bin/stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt 1000000 ]; then
            /bin/mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
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
        printf '"%s"' "$1"
    fi
}

write_state() {
    local ssh_part tmp
    if [ -n "$SSH_PID" ]; then ssh_part="$SSH_PID"; else ssh_part=""; fi
    tmp="$SUPPORT/state/.$ENTRY_ID.$$.tmp"
    printf '{"entry_id":"%s","wrapper_pid":%s,"ssh_pid":%s,"iterm_session_id":%s,"tty":%s,"started_at":%s}\n' \
        "$ENTRY_ID" "$$" \
        "$( [ -n "$ssh_part" ] && printf '%s' "$ssh_part" || printf 'null' )" \
        "$(json_string_or_null "${ITERM_GUID:-}")" \
        "$(json_string_or_null "${TTY_NAME:-}")" \
        "$STARTED_AT" >"$tmp" 2>/dev/null && /bin/mv -f "$tmp" "$STATE_FILE" 2>/dev/null
}

remove_state() {
    # Only remove the file when it still describes this wrapper: a newer wrapper
    # for the same entry may already have replaced it.
    if [ -f "$STATE_FILE" ] && /usr/bin/grep -q "\"wrapper_pid\":$$," "$STATE_FILE" 2>/dev/null; then
        /bin/rm -f "$STATE_FILE"
    fi
}

reset_terminal() {
    /bin/stty sane 2>/dev/null || true
    printf '%s' "$RESET_SEQ"
}

kill_ssh() {
    if [ -n "$SSH_PID" ]; then
        /bin/kill -9 "$SSH_PID" 2>/dev/null || true
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

# PIDs of iTerm2 sessions are children of the iTerm daemon; make sure we always
# have a tty even if the caller redirected something.
TTY_NAME=$(/usr/bin/tty 2>/dev/null | /usr/bin/sed 's|^/dev/||')
ITERM_GUID="${ITERM_SESSION_ID#*:}"
: "${ITERM_GUID:=}"

log "wrapper start pid=$$ tty=${TTY_NAME:-none} iTerm=${ITERM_GUID:-none}"

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

    /usr/bin/ssh -t "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD" </dev/tty >/dev/tty 2>&1 &
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
            # bash 3.2 reports a read timeout as status 1, the same as EOF, so this
            # loop simply keeps waiting: a reconnect request is noticed within a
            # second and a closed window is handled by the HUP trap.
            while [ "${RECONNECT_REQUESTED}" = "0" ]; do
                if read -r -t 1 _ </dev/tty 2>/dev/null; then
                    break
                fi
            done
            continue
            ;;
    esac
done
