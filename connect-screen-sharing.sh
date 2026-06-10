#!/bin/bash
# Run on your MacBook to reach the Mac mini's screen from offsite.
# Requires start-minion-tunnel.sh to already be running on the Mac mini.

REMOTE_HOST="homes.cels.anl.gov"
LOCAL_PORT=5901

if lsof -i :${LOCAL_PORT} -sTCP:LISTEN &>/dev/null; then
    echo "Tunnel already up on localhost:${LOCAL_PORT}."
else
    echo "Opening VNC tunnel through homes (MFA required)..."
    ssh -f -N -L ${LOCAL_PORT}:localhost:15900 "${REMOTE_HOST}"
    if [ $? -ne 0 ]; then
        echo "Tunnel failed to start."
        exit 1
    fi
    echo "Tunnel up."
fi

echo "Opening Screen Sharing..."
open "vnc://localhost:${LOCAL_PORT}"
