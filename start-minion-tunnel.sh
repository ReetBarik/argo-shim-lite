#!/bin/bash
# Bring up the Argo SSH tunnel (+ reverse VNC). Duo approval required.
#
# Delegates to the launchd service com.rbarik.minion-tunnel so there is a single,
# headless-safe start path: the service runs `ssh -N` under expect, which answers
# the Duo menu for you -- you just approve the push on your phone. Works the same
# whether run by hand, by the tunnel skill, or by the watchdog (tunnel-healthcheck.sh).
#
# Exits 0 once the tunnel is confirmed up, non-zero if it did not come up in time.

CONTROL_PATH="/tmp/ssh-argo-minion"
REMOTE_HOST="homes.cels.anl.gov"
TUNNEL_LABEL="com.rbarik.minion-tunnel"

if ssh -O check -o ControlPath="${CONTROL_PATH}" "${REMOTE_HOST}" 2>/dev/null; then
    echo "Tunnel already running on port 8085."
    exit 0
fi

echo "Starting Argo tunnel via launchd service (approve the Duo push on your phone)..."
launchctl kickstart "gui/$(id -u)/${TUNNEL_LABEL}"

# Wait up to ~2 min for the connection to establish (you approving the Duo push).
for _ in $(seq 1 24); do
    sleep 5
    if ssh -O check -o ControlPath="${CONTROL_PATH}" "${REMOTE_HOST}" 2>/dev/null; then
        echo "Tunnel up on port 8085 (Argo) and reverse VNC on homes:15900."
        exit 0
    fi
done

echo "Tunnel failed to start (Duo not approved in time, or auth failed)."
exit 1
