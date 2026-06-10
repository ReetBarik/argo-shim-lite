#!/bin/bash
# Start the SSH tunnel to Argo. Run once after boot — MFA required.
# The tunnel stays alive via keepalives; launchd manages the proxy and bot separately.

CONTROL_PATH="/tmp/ssh-argo-minion"
REMOTE_HOST="homes.cels.anl.gov"

if ssh -O check -o ControlPath="${CONTROL_PATH}" "${REMOTE_HOST}" 2>/dev/null; then
    echo "Tunnel already running on port 8085."
    exit 0
fi

echo "Starting SSH tunnel to Argo (MFA required)..."
ssh -f -N \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=60 \
    -o ControlMaster=yes \
    -o ControlPath="${CONTROL_PATH}" \
    -L 8085:apps.inside.anl.gov:443 \
    "${REMOTE_HOST}"

if [ $? -eq 0 ]; then
    echo "Tunnel up on port 8085."
else
    echo "Tunnel failed to start."
    exit 1
fi
