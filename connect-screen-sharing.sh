#!/bin/bash
# Run on your MacBook to reach the Mac mini's screen from offsite.
#
# Tries a DIRECT connection to the mini first -- fast, no MFA, and it works
# whenever you have a route to the mini's address (e.g. on the ANL VPN). If that
# fails it falls back to the reverse VNC tunnel through homes.cels.anl.gov, which
# works from anywhere but needs a Duo approval and requires start-minion-tunnel.sh
# to already be running on the mini.
#
# The mini posts its current address to #openclaw whenever it changes (report-ip.sh).
# Give it to this script in whichever way is least annoying:
#   ./connect-screen-sharing.sh 130.202.141.134   # paste from Discord
#   export MINION_DIRECT_IP=130.202.141.134       # or set it in your shell
#   echo 130.202.141.134 > ~/.minion-direct-ip    # or park it in a file
# With no address at all, the script goes straight to the tunnel as before.

REMOTE_HOST="rbarik@homes.cels.anl.gov"
JUMP_HOST="rbarik@logins.cels.anl.gov"
LOCAL_PORT=5901
VNC_PORT=5900
DIRECT_TIMEOUT=3          # seconds to decide the direct route is not available

DIRECT_IP="${1:-${MINION_DIRECT_IP:-}}"
if [ -z "${DIRECT_IP}" ] && [ -f "$HOME/.minion-direct-ip" ]; then
    DIRECT_IP=$(tr -d '[:space:]' < "$HOME/.minion-direct-ip")
fi

if [ -n "${DIRECT_IP}" ]; then
    echo "Trying direct connection to ${DIRECT_IP}:${VNC_PORT}..."
    if nc -z -G ${DIRECT_TIMEOUT} "${DIRECT_IP}" ${VNC_PORT} 2>/dev/null; then
        echo "Direct route works -- opening Screen Sharing (no MFA needed)."
        open "vnc://${DIRECT_IP}:${VNC_PORT}"
        exit 0
    fi
    echo "No direct route to ${DIRECT_IP} (off the VPN?) -- falling back to the tunnel."
fi

if lsof -i :${LOCAL_PORT} -sTCP:LISTEN &>/dev/null; then
    echo "Tunnel already up on localhost:${LOCAL_PORT}."
else
    echo "Opening VNC tunnel through homes (MFA required)..."
    if ! ssh -f -N -J "${JUMP_HOST}" -L ${LOCAL_PORT}:localhost:15900 "${REMOTE_HOST}"; then
        echo "Tunnel failed to start."
        exit 1
    fi
    echo "Tunnel up."
fi

echo "Opening Screen Sharing..."
open "vnc://localhost:${LOCAL_PORT}"
