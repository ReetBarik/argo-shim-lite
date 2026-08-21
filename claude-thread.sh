#!/bin/bash
# claude-thread.sh -- named, persistent Claude Code conversations that more
# than one party can talk to. The human asks from a terminal, an agent
# (Hermes/Minion) asks via its exec tool -- both land in the SAME conversation,
# so Claude keeps one shared planning context. Runs headless against Argo
# through the always-on Minion proxy (8084); no MFA, no new tunnel.
#
# Usage:
#   claude-thread.sh ask <thread> "<message>"    # append + get reply (creates thread)
#   claude-thread.sh attach <thread>             # interactive claude --resume (human)
#   claude-thread.sh threads                     # list threads
#
# Env overrides:
#   CLAUDE_THREAD_MODEL   main model   (default claude-opus-5; if Argo's Opus
#                         tier is hanging/502ing, use claude-sonnet-5)
#   ANTHROPIC_BASE_URL    default http://127.0.0.1:8084/argoapi/
#
# Notes:
#   - `claude -p --resume` keeps the session id stable, so a thread is just a
#     name -> session-id file. Verified 2026-08-21.
#   - Turn-based: a mkdir lock serializes writers so two asks can't interleave
#     one session. Don't `attach` while an ask is in flight.
#   - Threads run in their own workspace dir (not the live repo), and headless
#     mode leaves Claude's permission defaults intact -- unapproved tools are
#     denied, so a Discord-triggered ask can't mutate this machine.

set -u

STATE_DIR="${CLAUDE_THREAD_HOME:-$HOME/.claude-threads}"
WORKSPACE="${STATE_DIR}/workspace"
mkdir -p "${STATE_DIR}" "${WORKSPACE}"

CLAUDE_EXECUTABLE="${CLAUDE_EXECUTABLE:-claude}"
command -v "${CLAUDE_EXECUTABLE}" >/dev/null 2>&1 || CLAUDE_EXECUTABLE="$HOME/.local/bin/claude"

# Argo wiring: canonical model names (Claude Code rejects Argo's squashed ids),
# identity as bearer token, everything through the Minion proxy which injects
# auth and rides the shared tunnel.
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:8084/argoapi/}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-rbarik}"
export CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1
export ANTHROPIC_MODEL="${CLAUDE_THREAD_MODEL:-claude-opus-5}"
export ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-claude-haiku-4-5}"

lock() {
    # mkdir is atomic and portable (macOS has no flock). ~5 min timeout covers
    # a slow model turn; a lock older than 30 min is presumed dead and broken.
    local lockdir="${STATE_DIR}/$1.lock" waited=0
    if [ -d "${lockdir}" ] && [ -n "$(find "${lockdir}" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rmdir "${lockdir}" 2>/dev/null
    fi
    until mkdir "${lockdir}" 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
        if [ ${waited} -ge 300 ]; then
            echo "thread '$1' is busy (another ask in flight); try again shortly" >&2
            return 1
        fi
    done
    trap "rmdir '${lockdir}' 2>/dev/null" EXIT
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "${cmd}" in
    ask)
        thread="${1:?thread name required}"; shift
        msg="${*:?message required}"
        idfile="${STATE_DIR}/${thread}.id"
        lock "${thread}" || exit 75
        cd "${WORKSPACE}"
        if [ -s "${idfile}" ]; then
            out="$("${CLAUDE_EXECUTABLE}" -p --resume "$(cat "${idfile}")" --output-format json "${msg}" 2>/dev/null)"
        else
            out="$("${CLAUDE_EXECUTABLE}" -p --output-format json "${msg}" 2>/dev/null)"
        fi
        printf '%s' "${out}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("claude produced no parseable output (proxy/tunnel down? model rejected?)", file=sys.stderr)
    sys.exit(1)
sid = d.get("session_id", "")
if sid:
    open(sys.argv[1], "w").write(sid)
if d.get("is_error"):
    print("thread error:", d.get("result", "unknown"), file=sys.stderr)
    sys.exit(1)
print(d.get("result", ""))
' "${idfile}" ;;

    attach)
        thread="${1:?thread name required}"
        idfile="${STATE_DIR}/${thread}.id"
        [ -s "${idfile}" ] || { echo "no such thread: ${thread} (use: ask ${thread} \"...\")" >&2; exit 66; }
        cd "${WORKSPACE}"
        exec "${CLAUDE_EXECUTABLE}" --resume "$(cat "${idfile}")" ;;

    threads|"")
        found=0
        for f in "${STATE_DIR}"/*.id; do
            [ -e "${f}" ] || continue
            found=1
            t="$(basename "${f}" .id)"
            printf '%-24s %s\n' "${t}" "$(cat "${f}")"
        done
        [ ${found} -eq 0 ] && echo "no threads yet (claude-thread.sh ask <name> \"...\")"
        exit 0 ;;

    *)
        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
