#!/bin/bash

# Launch OpenClaw against the Argo backend.
#
# Usage: argonne-openclaw.sh [--identity=<anl-username>]
#
# Uses its own dedicated SSH tunnel (port 8085) and proxy (port 8084) so it
# can run independently or alongside argonne-claude.sh without port conflicts.

IDENTITY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --identity=*) IDENTITY="${1#--identity=}"; shift ;;
        --identity)   IDENTITY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_EXECUTABLE="${OPENCLAW_EXECUTABLE:-openclaw}"

REMOTE_HOST="homes.cels.anl.gov"
TUNNEL_LOCAL_PORT=8085
TUNNEL_REMOTE_HOST="apps.inside.anl.gov"
TUNNEL_REMOTE_PORT=443
PROXY_PORT=8084

ARGO_AURORA_UAN="${ARGO_AURORA_UAN:-${PBS_O_HOST:-aurora-uan-0011}}"
if [ -z "${ARGO_SSH_JUMP}" ] && [ -n "${PBS_JOBID}" ]; then
    ARGO_SSH_JUMP="${ARGO_AURORA_UAN},logins.cels.anl.gov"
fi

CONTROL_PATH="/tmp/ssh-argo-openclaw-$$"
PROXY_PID=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [ -n "${PROXY_PID}" ]; then
        kill "${PROXY_PID}" 2>/dev/null
    fi
    ssh -O exit -o ControlPath="${CONTROL_PATH}" "${REMOTE_HOST}" 2>/dev/null || true
    echo -e "${GREEN}Done!${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

ARGO_IDENTITY="${IDENTITY:-${ARGO_USER:-$USER}}"

# ── Step 1: SSH tunnel on port 8085 ──────────────────────────────────────────

if lsof -i :${TUNNEL_LOCAL_PORT} >/dev/null 2>&1; then
    echo -e "${RED}Port ${TUNNEL_LOCAL_PORT} is already in use.${NC}"
    echo -e "${YELLOW}Check for an existing tunnel: lsof -i :${TUNNEL_LOCAL_PORT}${NC}"
    exit 1
fi

echo -e "${YELLOW}Starting SSH tunnel to ${TUNNEL_REMOTE_HOST}...${NC}"
echo -e "${YELLOW}(You may need to complete MFA authentication)${NC}"

SSH_JUMP_OPTS=()
if [ -n "${ARGO_SSH_JUMP}" ]; then
    SSH_JUMP_OPTS=(-J "${ARGO_SSH_JUMP}")
    echo -e "${YELLOW}Using SSH jump chain: ${ARGO_SSH_JUMP}${NC}"
fi

ssh -f -N \
    "${SSH_JUMP_OPTS[@]}" \
    -o ControlMaster=yes \
    -o ControlPath="${CONTROL_PATH}" \
    -L ${TUNNEL_LOCAL_PORT}:${TUNNEL_REMOTE_HOST}:${TUNNEL_REMOTE_PORT} \
    "${REMOTE_HOST}"

if [ $? -ne 0 ]; then
    echo -e "${RED}SSH tunnel failed to start. Check your credentials and MFA.${NC}"
    exit 1
fi

echo -e "${GREEN}SSH tunnel established (port ${TUNNEL_LOCAL_PORT}).${NC}"

# ── Step 2: OpenClaw proxy on port 8084 ──────────────────────────────────────

if lsof -i :${PROXY_PORT} >/dev/null 2>&1; then
    echo -e "${RED}Port ${PROXY_PORT} is already in use.${NC}"
    echo -e "${YELLOW}Check for an existing proxy: lsof -i :${PROXY_PORT}${NC}"
    exit 1
fi

echo -e "${YELLOW}Starting OpenClaw proxy on port ${PROXY_PORT}...${NC}"

VENV="${SCRIPT_DIR}/.venv"
if [ -d "${VENV}" ]; then
    PYTHON="${VENV}/bin/python3"
else
    PYTHON="python3"
fi

ARGO_USER="${ARGO_IDENTITY}" "${PYTHON}" "${SCRIPT_DIR}/openclaw-argo-proxy.py" &
PROXY_PID=$!

sleep 2

if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo -e "${RED}Proxy failed to start. Is aiohttp installed?${NC}"
    exit 1
fi

echo -e "${GREEN}OpenClaw proxy running (port ${PROXY_PORT}).${NC}"

# ── Step 3: Launch OpenClaw ───────────────────────────────────────────────────

echo -e "${GREEN}Launching OpenClaw as ${ARGO_IDENTITY}...${NC}"
${OPENCLAW_EXECUTABLE}
