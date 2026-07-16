#!/bin/bash
# Watchdog for the Argo SSH tunnel (port 8085) that Minion/OpenClaw depends on.
#
# Runs headless under launchd (com.rbarik.minion-tunnel-check) at 8 AM Central and
# every 2 hours until 8 PM. If the tunnel is down it posts to #openclaw on Discord
# and re-runs start-minion-tunnel.sh, which fires a Duo push. Because Duo is
# interactive, this only *initiates* the restart -- you must approve the push on
# your phone. If you miss it, the next scheduled run tries again.
#
# Usage:
#   tunnel-healthcheck.sh              # normal watchdog run (used by launchd)
#   tunnel-healthcheck.sh test-notify  # send a test Discord message and exit
#   tunnel-healthcheck.sh force        # run the restart path even if the tunnel is up

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTROL_PATH="/tmp/ssh-argo-minion"          # must match start-minion-tunnel.sh
REMOTE_HOST="homes.cels.anl.gov"
DISCORD_CHANNEL_ID="1509722172787003603"     # #openclaw
SECRETS="$HOME/.minion-secrets"
LOG="$HOME/.minion-logs/tunnel-check.log"
PY="$SCRIPT_DIR/.venv/bin/python3"
[ -x "$PY" ] || PY="/usr/bin/python3"

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG"; }

# Load DISCORD_TOKEN (and friends) from the secrets file.
DISCORD_TOKEN="${DISCORD_TOKEN:-}"
if [ -f "$SECRETS" ]; then
    # shellcheck disable=SC1090
    . "$SECRETS"
fi

notify() {
    local msg="$1"
    log "notify: $msg"
    if [ -z "${DISCORD_TOKEN:-}" ]; then
        log "WARN: DISCORD_TOKEN not set; cannot post to Discord"
        return 1
    fi
    local payload
    payload=$("$PY" -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$msg")
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Authorization: Bot ${DISCORD_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$payload" \
        "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages")
    log "discord POST -> HTTP $code"
    [ "$code" = "200" ]
}

is_up() {
    ssh -O check -o ControlPath="$CONTROL_PATH" "$REMOTE_HOST" >/dev/null 2>&1
}

attempt_restart() {
    log "tunnel DOWN -- alerting and attempting restart"
    notify ":warning: **Argo tunnel is DOWN** on $(hostname). Restarting now -- **approve the Duo push on your phone.** If you miss it, I'll retry at the next check."

    # start-minion-tunnel.sh kicks the launchd tunnel service and waits (~2 min)
    # for the connection to establish, returning 0 only once it is confirmed up.
    if "$SCRIPT_DIR/start-minion-tunnel.sh" >> "$LOG" 2>&1; then
        notify ":white_check_mark: Argo tunnel is back up on $(hostname)."
        log "tunnel restored"
        return 0
    fi

    notify ":x: Tunnel restart did not complete (Duo not approved in time, or auth failed). Will retry at the next scheduled check."
    log "restart timed out"
    return 1
}

case "${1:-}" in
    test-notify)
        notify ":test_tube: Tunnel watchdog test message from $(hostname) at $(date '+%H:%M %Z')."
        exit $?
        ;;
    force)
        attempt_restart
        exit $?
        ;;
    *)
        if is_up; then
            log "tunnel UP -- no action"
            exit 0
        fi
        attempt_restart
        exit $?
        ;;
esac
