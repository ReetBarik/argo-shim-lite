#!/bin/bash
# Post this Mac mini's current primary IP to #openclaw so you can reach it from
# home (see connect-screen-sharing.sh, which takes the IP as its first argument).
#
# Runs headless under launchd (com.rbarik.minion-ip-report): at load/boot, every
# 15 minutes, and whenever the network configuration changes. It is deliberately
# QUIET -- it only posts when the address actually changed, or on the first run
# after a reboot. A steady IP produces no Discord traffic at all, same philosophy
# as tunnel-healthcheck.sh.
#
# Usage:
#   report-ip.sh              # normal run (used by launchd); posts only on change
#   report-ip.sh force        # post the current IP no matter what
#   report-ip.sh show         # print what would be reported, post nothing

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISCORD_CHANNEL_ID="1509722172787003603"     # #openclaw, same as tunnel-healthcheck.sh
SECRETS="$HOME/.minion-secrets"
STATE="$HOME/.minion-logs/last-ip"           # last address we successfully reported
LOG="$HOME/.minion-logs/ip-report.log"
SETTLE_TRIES=6                               # ~30s of grace for DHCP after a network change
SETTLE_SLEEP=5
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
    log "notify: $(echo "$msg" | head -1)"
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

# The address worth reporting is the one on whichever interface currently holds
# the default route -- this box has a second NIC (en0) that idles at a 169.254
# link-local address, and reporting that would be useless.
primary_iface() {
    route -n get default 2>/dev/null | awk '/interface:/{print $2}'
}

primary_ip() {
    local iface ip
    iface="$(primary_iface)"
    [ -n "$iface" ] || return 1
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
    # ipconfig only knows DHCP-configured interfaces; fall back for static ones.
    [ -n "$ip" ] || ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
    [ -n "$ip" ] || return 1
    case "$ip" in 169.254.*) return 1 ;; esac   # link-local == no lease yet
    printf '%s\n' "$ip"
}

# launchd fires us the moment resolv.conf changes, which can be before DHCP has
# handed out an address. Wait a little rather than reporting nothing.
settled_ip() {
    local i ip
    for i in $(seq 1 "$SETTLE_TRIES"); do
        if ip=$(primary_ip); then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep "$SETTLE_SLEEP"
    done
    return 1
}

# True if we have not reported anything since the machine last booted. Lets a
# reboot always produce a message, even when DHCP hands back the same lease.
booted_since_last_report() {
    local boot_epoch state_epoch
    # kern.boottime reads "{ sec = 1781108182, usec = 461014 } Wed Jun 10 ...".
    # Take the FIRST number: a greedy ".*sec = " also matches the "sec = " inside
    # "usec = " and would silently hand back the microseconds instead.
    boot_epoch=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+).*/\1/')
    [ -n "$boot_epoch" ] || return 1
    [ -f "$STATE" ] || return 0
    state_epoch=$(stat -f %m "$STATE" 2>/dev/null) || return 0
    [ "$state_epoch" -lt "$boot_epoch" ]
}

compose() {
    local ip="$1" headline="$2" iface
    iface="$(primary_iface)"
    printf ':satellite: %s\n`%s` (%s on %s)\nFrom home: `./connect-screen-sharing.sh %s`  ·  `ssh %s@%s`' \
        "$headline" "$ip" "$iface" "$(hostname -s)" "$ip" "$(id -un)" "$ip"
}

IP="$(settled_ip)" || { log "no usable IP (link-local or no default route); staying quiet"; exit 0; }

case "${1:-}" in
    show)
        echo "primary iface : $(primary_iface)"
        echo "primary ip    : ${IP}"
        echo "last reported : $( [ -f "$STATE" ] && cat "$STATE" || echo '(none)' )"
        echo "--- message ---"
        compose "$IP" "**Mac mini IP**"
        echo
        exit 0
        ;;
    force)
        notify "$(compose "$IP" "**Mac mini IP**")" && printf '%s\n' "$IP" > "$STATE"
        exit $?
        ;;
esac

LAST=""
[ -f "$STATE" ] && LAST="$(cat "$STATE")"

if [ "$IP" = "$LAST" ] && ! booted_since_last_report; then
    log "IP unchanged (${IP}) -- no action"
    exit 0
fi

if [ -z "$LAST" ]; then
    HEADLINE="**Mac mini IP**"
elif [ "$IP" = "$LAST" ]; then
    HEADLINE="**Mac mini rebooted** — same IP as before"
else
    HEADLINE="**Mac mini IP changed** (was \`${LAST}\`)"
fi

# Only record the address once Discord actually accepted the message, so a failed
# post is retried on the next run instead of being silently swallowed.
if notify "$(compose "$IP" "$HEADLINE")"; then
    printf '%s\n' "$IP" > "$STATE"
    log "reported ${IP}"
    exit 0
fi

log "failed to report ${IP}; will retry on next run"
exit 1
