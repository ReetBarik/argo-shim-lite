#!/bin/bash

# Defaults
BACKEND=""
IDENTITY=""
# Which discovered model becomes the main model: 'plan' -> best Opus,
# 'exec' -> best Sonnet. Both are always resolved and exported as the
# /model opus | /model sonnet aliases, so switching mid-session is instant.
TIER="${CLAUDE_TIER:-plan}"

# Parse args. Only --backend / --identity / --tier are consumed; anything else is ignored.
while [ $# -gt 0 ]; do
    case "$1" in
        --backend=*)
            BACKEND="${1#--backend=}"
            shift
            ;;
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --identity=*)
            IDENTITY="${1#--identity=}"
            shift
            ;;
        --identity)
            IDENTITY="$2"
            shift 2
            ;;
        --tier=*)
            TIER="${1#--tier=}"
            shift
            ;;
        --tier)
            TIER="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ "${TIER}" != "plan" ] && [ "${TIER}" != "exec" ]; then
    echo "Unknown --tier: ${TIER} (use plan or exec)" >&2
    exit 1
fi

CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE:-claude}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Run Claude Code's built-in updater before launch so every session starts on
# the latest version. Never fatal: no network (compute nodes), a read-only
# install, or a timeout just launches the installed version. Skip with
# CLAUDE_AUTO_UPDATE=0 (or the standard DISABLE_AUTOUPDATER=1).
maybe_update_claude() {
    [ "${CLAUDE_AUTO_UPDATE:-1}" = "0" ] && return 0
    [ "${DISABLE_AUTOUPDATER:-0}" = "1" ] && return 0
    command -v "${CLAUDE_EXECUTABLE}" >/dev/null 2>&1 || return 0
    echo -e "${YELLOW}Checking for Claude Code updates...${NC}"
    local runner=() out
    command -v timeout >/dev/null 2>&1 && runner=(timeout 90)
    if out="$("${runner[@]}" "${CLAUDE_EXECUTABLE}" update 2>&1)"; then
        printf '%s\n' "${out}" | tail -2
    else
        echo -e "${YELLOW}Update check failed or timed out; launching the installed version.${NC}"
    fi
}

# Print the first free localhost port >= $1 (scans 50 ports). Empty on failure.
find_free_port() {
    python3 - "$1" <<'PY'
import socket, sys
start = int(sys.argv[1])
for port in range(start, start + 50):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        s.close()
        print(port)
        sys.exit(0)
    except OSError:
        s.close()
sys.exit(1)
PY
}

# Extract model ids from a /v1/models JSON payload on stdin, one per line.
extract_model_ids() {
    python3 -c '
import json, sys
try:
    print("\n".join(m.get("id","") for m in json.load(sys.stdin).get("data", []) if m.get("id")))
except Exception:
    pass
' 2>/dev/null
}

# Rank $AVAILABLE_IDS and set BEST_OPUS / BEST_SONNET / BEST_HAIKU.
pick_best_models() {
    BEST_OPUS=""; BEST_SONNET=""; BEST_HAIKU=""
    [ -z "${AVAILABLE_IDS}" ] && return
    local picks
    picks="$(printf '%s\n' "${AVAILABLE_IDS}" | python3 "${SCRIPT_DIR}/pick-models.py" 2>/dev/null)"
    BEST_OPUS="$(printf '%s\n' "${picks}" | sed -n 's/^BEST_OPUS=//p')"
    BEST_SONNET="$(printf '%s\n' "${picks}" | sed -n 's/^BEST_SONNET=//p')"
    BEST_HAIKU="$(printf '%s\n' "${picks}" | sed -n 's/^BEST_HAIKU=//p')"
}

# Fill the MODEL_ENV array from BEST_* + tier. $1/$2: user overrides for the
# main and small/fast model (empty = use discovery).
build_model_env() {
    local main_override="$1" fast_override="$2" main="" fast=""
    MODEL_ENV=()
    if [ -n "${main_override}" ]; then
        main="${main_override}"
    elif [ "${TIER}" = "exec" ]; then
        main="${BEST_SONNET:-${BEST_OPUS}}"
    else
        main="${BEST_OPUS:-${BEST_SONNET}}"
    fi
    fast="${fast_override:-${BEST_HAIKU}}"

    if [ -n "${main}" ]; then
        MODEL_ENV+=("ANTHROPIC_MODEL=${main}")
        echo -e "${GREEN}Main model (--tier=${TIER}): ${main}${NC}"
    else
        echo -e "${YELLOW}Could not discover a main model; Claude Code will use its default (may fail against this backend).${NC}"
    fi
    if [ -n "${fast}" ]; then
        # ANTHROPIC_SMALL_FAST_MODEL is deprecated in favor of
        # ANTHROPIC_DEFAULT_HAIKU_MODEL; set both for older binaries.
        MODEL_ENV+=("ANTHROPIC_SMALL_FAST_MODEL=${fast}")
        echo -e "${GREEN}Small/fast model: ${fast}${NC}"
    fi
    # Pin the in-session /model aliases to the best discovered ids so
    # switching tiers mid-session is just `/model opus` or `/model sonnet`.
    [ -n "${BEST_OPUS}" ]   && MODEL_ENV+=("ANTHROPIC_DEFAULT_OPUS_MODEL=${BEST_OPUS}")
    [ -n "${BEST_SONNET}" ] && MODEL_ENV+=("ANTHROPIC_DEFAULT_SONNET_MODEL=${BEST_SONNET}")
    [ -n "${fast}" ]        && MODEL_ENV+=("ANTHROPIC_DEFAULT_HAIKU_MODEL=${fast}")
    if [ -n "${BEST_OPUS}" ] && [ -n "${BEST_SONNET}" ]; then
        echo -e "${YELLOW}Switch anytime with /model opus (${BEST_OPUS}) or /model sonnet (${BEST_SONNET}).${NC}"
    fi
    # The tier implies the reasoning effort, so it's one decision, not two:
    # plan -> xhigh (best for design/planning work; downgraded to high when
    # the picked model predates xhigh support), exec -> high (the
    # cost/quality sweet spot, valid on every Claude model). An explicitly
    # exported CLAUDE_CODE_EFFORT_LEVEL always wins.
    if [ -z "${CLAUDE_CODE_EFFORT_LEVEL+set}" ]; then
        local effort="high"
        if [ "${TIER}" = "plan" ]; then
            case "${main}" in
                *opus-5*|*opus-4-7*|*opus-4-8*|*sonnet-5*|*fable*|*mythos*)
                    effort="xhigh" ;;
            esac
        fi
        MODEL_ENV+=("CLAUDE_CODE_EFFORT_LEVEL=${effort}")
        echo -e "${GREEN}Reasoning effort (--tier=${TIER}): ${effort}${NC}"
    fi
}

run_argo() {
    # Configuration. Ports are starting points — the launcher probes upward
    # from each and uses the first free one, so stale tunnels or other
    # services on the defaults no longer require manual edits.
    REMOTE_HOST="homes.cels.anl.gov"
    TUNNEL_REMOTE_HOST="apps.inside.anl.gov"
    TUNNEL_REMOTE_PORT=443

    # SSH jump chain. On Aurora compute nodes ($PBS_JOBID set) the default
    # routes through a UAN; PBS records the submitting UAN in $PBS_O_HOST.
    # Users can override either the UAN or the whole chain.
    ARGO_AURORA_UAN="${ARGO_AURORA_UAN:-${PBS_O_HOST:-aurora-uan-0011}}"
    if [ -z "${ARGO_SSH_JUMP}" ] && [ -n "${PBS_JOBID}" ]; then
        ARGO_SSH_JUMP="${ARGO_AURORA_UAN},logins.cels.anl.gov"
    fi

    # SSH ControlMaster settings
    CONTROL_PATH="/tmp/ssh-argo-claude-$$"

    # Track PIDs for cleanup
    PROXY_PID=""

    cleanup() {
        echo -e "\n${YELLOW}Cleaning up...${NC}"

        if [ -n "${PROXY_PID}" ]; then
            kill ${PROXY_PID} 2>/dev/null
        fi

        # Close the SSH tunnel via control socket
        ssh -O exit -o ControlPath="${CONTROL_PATH}" ${REMOTE_HOST} 2>/dev/null || true

        echo -e "${GREEN}Done!${NC}"
        exit 0
    }

    trap cleanup SIGINT SIGTERM EXIT

    echo -e "${GREEN}Starting Argo Claude setup...${NC}"

    # Probe for a free tunnel port (starting at ARGO_TUNNEL_PORT or 8082)
    TUNNEL_LOCAL_PORT="$(find_free_port "${ARGO_TUNNEL_PORT:-8082}")"
    if [ -z "${TUNNEL_LOCAL_PORT}" ]; then
        echo -e "${RED}No free port found for the SSH tunnel (tried 50 ports from ${ARGO_TUNNEL_PORT:-8082}).${NC}"
        exit 1
    fi

    # Step 1: Start SSH tunnel (ssh -f backgrounds after MFA authentication completes)
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
        -o AddressFamily=inet \
        -o ExitOnForwardFailure=yes \
        -L 127.0.0.1:${TUNNEL_LOCAL_PORT}:${TUNNEL_REMOTE_HOST}:${TUNNEL_REMOTE_PORT} \
        ${REMOTE_HOST}

    if [ $? -ne 0 ]; then
        echo -e "${RED}SSH tunnel failed to start. Check your credentials and MFA.${NC}"
        exit 1
    fi

    # Verify the forward is actually listening before we trust ssh -f's exit code.
    if command -v ss >/dev/null 2>&1; then
        LISTEN_CHECK="ss -tln"
    else
        LISTEN_CHECK="lsof -iTCP:${TUNNEL_LOCAL_PORT} -sTCP:LISTEN -n -P"
    fi
    if ! ${LISTEN_CHECK} 2>/dev/null | grep -q ":${TUNNEL_LOCAL_PORT}\b"; then
        echo -e "${RED}SSH tunnel appears not to be listening on 127.0.0.1:${TUNNEL_LOCAL_PORT}.${NC}"
        exit 1
    fi

    echo -e "${GREEN}SSH tunnel established (127.0.0.1:${TUNNEL_LOCAL_PORT})!${NC}"

    # Step 2: Start local proxy on a probed free port (retry a few times in
    # case another process grabs the port between the probe and the bind).
    echo -e "${YELLOW}Starting local proxy...${NC}"

    PROXY_PORT=""
    PROXY_START="${ARGO_PROXY_PORT:-8083}"
    for _attempt in 1 2 3; do
        PROXY_PORT="$(find_free_port "${PROXY_START}")"
        if [ -z "${PROXY_PORT}" ]; then
            break
        fi
        ARGO_PROXY_LISTEN_PORT="${PROXY_PORT}" \
            ARGO_PROXY_TARGET_PORT="${TUNNEL_LOCAL_PORT}" \
            ARGO_PROXY_TARGET_HOST="${TUNNEL_REMOTE_HOST}" \
            python3.12 "${SCRIPT_DIR}/claude-argo-proxy.py" &
        PROXY_PID=$!
        sleep 2
        if kill -0 ${PROXY_PID} 2>/dev/null; then
            break
        fi
        PROXY_PID=""
        PROXY_START=$((PROXY_PORT + 1))
    done

    if [ -z "${PROXY_PID}" ]; then
        echo -e "${RED}Local proxy failed to start. Is aiohttp installed? (pip install aiohttp)${NC}"
        exit 1
    fi

    echo -e "${GREEN}Local proxy running (port ${PROXY_PORT})!${NC}"

    # Identity precedence: --identity > $ARGO_USER > $USER
    ARGO_IDENTITY="${IDENTITY:-${ARGO_USER:-$USER}}"

    # Step 3: Discover the model catalog through the proxy and pick the best
    # Opus / Sonnet / Haiku. ARGO_MODEL / ARGO_SMALL_FAST_MODEL short-circuit.
    AVAILABLE_IDS=""
    if [ -z "${ARGO_MODEL}" ] || [ -z "${ARGO_SMALL_FAST_MODEL}" ]; then
        echo -e "${YELLOW}Querying Argo for available models...${NC}"
        AVAILABLE_IDS="$(curl -sS --max-time 10 \
            -H "Authorization: Bearer ${ARGO_IDENTITY}" \
            -H "anthropic-version: 2023-06-01" \
            "http://127.0.0.1:${PROXY_PORT}/argoapi/v1/models" 2>/dev/null | extract_model_ids)"
        if [ -z "${AVAILABLE_IDS}" ]; then
            echo -e "${YELLOW}Model discovery failed (endpoint may not expose /v1/models); set ARGO_MODEL to pin one.${NC}"
        fi
    fi
    pick_best_models
    build_model_env "${ARGO_MODEL}" "${ARGO_SMALL_FAST_MODEL}"

    # Step 4: Launch Claude Code
    # Default to the inline renderer — friendlier over multi-hop SSH (e.g. compute
    # nodes), and preserves Claude's output in scrollback. User can override.
    echo -e "${GREEN}Launching Claude Code as ${ARGO_IDENTITY}...${NC}"
    env \
        ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}/argoapi/" \
        ANTHROPIC_AUTH_TOKEN="${ARGO_IDENTITY}" \
        CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 \
        CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=${CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-1} \
        "${MODEL_ENV[@]}" \
        ${CLAUDE_EXECUTABLE}

    # The cleanup function will be called automatically by the trap on exit
}

run_asksage() {
    ASKSAGE_BASE_URL="${ASKSAGE_BASE_URL:-https://api.asksage.anl.gov/server/anthropic}"
    ASKSAGE_TOKEN_FILE="${ASKSAGE_TOKEN_FILE:-$HOME/.asksage/token}"

    echo -e "${GREEN}Starting AskSage Claude setup...${NC}"

    # Resolve API key. Precedence: --identity > $ASKSAGE_API_KEY > token file.
    if [ -n "${IDENTITY}" ]; then
        ASKSAGE_API_KEY="${IDENTITY}"
    elif [ -z "${ASKSAGE_API_KEY}" ] && [ -r "${ASKSAGE_TOKEN_FILE}" ]; then
        ASKSAGE_API_KEY="$(tr -d '[:space:]' < "${ASKSAGE_TOKEN_FILE}")"
    fi

    if [ -z "${ASKSAGE_API_KEY}" ]; then
        echo -e "${RED}No AskSage API key found.${NC}"
        echo -e "${YELLOW}Pass --identity=<api-key>, set \$ASKSAGE_API_KEY, or write the key to ${ASKSAGE_TOKEN_FILE}.${NC}"
        exit 1
    fi

    # The ANL AskSage server (api.asksage.anl.gov) does not include the
    # InCommon intermediate in its TLS chain, which makes Node's bundled CA
    # store (which has the USERTrust root but not the intermediate) fail to
    # verify. Add the intermediate explicitly so Claude Code's embedded Node
    # can complete the chain. NODE_EXTRA_CA_CERTS extends, not replaces, the
    # built-in roots, so this is safe for any tenant.
    ASKSAGE_EXTRA_CA="${SCRIPT_DIR}/certs/incommon-rsa-server-ca-2.pem"

    # Discover the model catalog. AskSage's /v1/models returns entries in
    # capability order (most-capable first). User can short-circuit the
    # selection via ASKSAGE_MODEL / ASKSAGE_SMALL_FAST_MODEL.
    AVAILABLE_IDS=""
    if [ -z "${ASKSAGE_MODEL}" ] || [ -z "${ASKSAGE_SMALL_FAST_MODEL}" ]; then
        echo -e "${YELLOW}Querying AskSage for available models...${NC}"
        MODELS_JSON="$(curl -sS --max-time 10 \
            --cacert "${ASKSAGE_EXTRA_CA}" \
            -H "Authorization: Bearer ${ASKSAGE_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            "${ASKSAGE_BASE_URL}/v1/models" 2>/dev/null)"
        if [ -n "${MODELS_JSON}" ] && command -v python3 >/dev/null 2>&1; then
            AVAILABLE_IDS="$(printf '%s' "${MODELS_JSON}" | extract_model_ids)"
        fi
    fi

    # Probe whether the backend accepts Claude Code's newer adaptive-thinking
    # mode (`thinking: {type: "adaptive"}`, Opus 4.7's default). The legacy
    # discriminated union only knows 'enabled' / 'disabled'. When the backend
    # rejects, two things have to change: (1) set
    # CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING so Claude Code falls back to the
    # legacy mode for models where the env var is honored, and (2) pick a
    # model where it IS honored (the binary only checks the env var for model
    # names containing "opus-4-6" or "sonnet-4-6"). When AskSage eventually
    # supports adaptive, the probe stops finding the rejection and the
    # 4-7-class model is picked normally. Skip the probe entirely if the user
    # already set CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING.
    ADAPTIVE_OK=1
    if [ -z "${CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING+set}" ]; then
        echo -e "${YELLOW}Probing adaptive-thinking support...${NC}"
        PROBE_MODEL="$(printf '%s\n' "${AVAILABLE_IDS}" | grep -i 'haiku' | head -1)"
        PROBE_MODEL="${PROBE_MODEL:-claude-haiku-4-5}"
        PROBE_RESP="$(curl -sS --max-time 10 \
            --cacert "${ASKSAGE_EXTRA_CA}" \
            -H "Authorization: Bearer ${ASKSAGE_API_KEY}" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -d "{\"model\":\"${PROBE_MODEL}\",\"max_tokens\":1,\"thinking\":{\"type\":\"adaptive\"},\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
            "${ASKSAGE_BASE_URL}/v1/messages" 2>/dev/null)"
        if printf '%s' "${PROBE_RESP}" | grep -q "Input tag 'adaptive'"; then
            export CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1
            ADAPTIVE_OK=0
            echo -e "${YELLOW}Backend rejects adaptive thinking; disabling.${NC}"
        elif [ -z "${PROBE_RESP}" ]; then
            echo -e "${YELLOW}Adaptive-thinking probe got no response; assuming supported.${NC}"
        else
            echo -e "${GREEN}Adaptive thinking supported.${NC}"
        fi
    fi

    # Rank the catalog and pick the best Opus / Sonnet / Haiku. When the
    # backend rejects adaptive thinking, restrict candidates to
    # opus-4-6 / sonnet-4-6 — the only family where
    # CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING actually has effect — falling
    # back to any non-4-7 model, then to the full catalog.
    if [ "${ADAPTIVE_OK}" != "1" ] && [ -n "${AVAILABLE_IDS}" ]; then
        LEGACY_IDS="$(printf '%s\n' "${AVAILABLE_IDS}" | grep -E 'opus-4-6|sonnet-4-6|haiku')"
        [ -z "${LEGACY_IDS}" ] && LEGACY_IDS="$(printf '%s\n' "${AVAILABLE_IDS}" | grep -v '4-7')"
        if [ -n "${LEGACY_IDS}" ] && [ "${LEGACY_IDS}" != "${AVAILABLE_IDS}" ]; then
            echo -e "${YELLOW}Restricting to legacy-thinking models: this backend rejects adaptive thinking.${NC}"
            AVAILABLE_IDS="${LEGACY_IDS}"
        fi
    fi
    pick_best_models
    build_model_env "${ASKSAGE_MODEL}" "${ASKSAGE_SMALL_FAST_MODEL}"

    echo -e "${GREEN}Launching Claude Code against AskSage (${ASKSAGE_BASE_URL})...${NC}"
    env \
        ANTHROPIC_BASE_URL="${ASKSAGE_BASE_URL}" \
        ANTHROPIC_AUTH_TOKEN="${ASKSAGE_API_KEY}" \
        CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$ASKSAGE_EXTRA_CA}" \
        "${MODEL_ENV[@]}" \
        ${CLAUDE_EXECUTABLE}
}

if [ -z "${BACKEND}" ]; then
    echo -e "${RED}--backend is required.${NC}" >&2
    echo -e "${YELLOW}Use --backend=argo or --backend=asksage${NC}" >&2
    exit 1
fi

maybe_update_claude

case "${BACKEND}" in
    argo)
        run_argo
        ;;
    asksage)
        run_asksage
        ;;
    *)
        echo -e "${RED}Unknown backend: ${BACKEND}${NC}" >&2
        echo -e "${YELLOW}Use --backend=argo or --backend=asksage${NC}" >&2
        exit 1
        ;;
esac
