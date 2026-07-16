#!/bin/bash
# Foreground Argo tunnel service. Started on demand by the launchd job
# com.rbarik.minion-tunnel (RunAtLoad=false, KeepAlive=false) -- normally kicked
# by tunnel-healthcheck.sh (or start-minion-tunnel.sh) when the tunnel is down.
#
# Runs `ssh -N` under expect so the Duo menu is answered automatically ("1" = Duo
# Push); you approve the push on your phone. expect holds the foreground ssh open
# for the life of the tunnel. When ssh dies, this process exits, the launchd job
# goes idle, and the next watchdog check restarts it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec /usr/bin/expect -f "${SCRIPT_DIR}/tunnel-up.exp" /usr/bin/ssh -N \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=60 \
    -o ControlMaster=yes \
    -o ControlPath=/tmp/ssh-argo-minion \
    -L 8085:apps.inside.anl.gov:443 \
    -R 15900:localhost:5900 \
    homes.cels.anl.gov
