#!/bin/bash
# remote-master.sh -- human-in-the-loop SSH ControlMasters for ANL systems.
#
# Separates AUTHENTICATION (a human approves a Duo push or supplies a MobilePASS
# passcode, once per master) from USE (any local process runs commands over the
# persisted master with no credentials, indefinitely). This is what lets an
# agent work on JLSE/ALCF while the human stays in the auth loop: the agent can
# check/use a master but can never mint one without you.
#
# Usage:
#   remote-master.sh targets                    # list targets
#   remote-master.sh status <target>            # 0 = master up
#   remote-master.sh up     <target>            # authenticate (secret on stdin when needed)
#   remote-master.sh stop   <target>            # close the master
#   remote-master.sh run    <target> <cmd...>   # exec over the master; never prompts
#
# Secrets go on stdin, never argv:
#   ./remote-master.sh up jlse                                # Duo push only
#   printf '%s\n' <passcode>  | ./remote-master.sh up aurora  # MobilePASS OTP
#   printf '%s\n' <password>  | ./remote-master.sh up jlse    # if JLSE wants a password before Duo
#
# The "cels" target deliberately REUSES the production Minion master
# (/tmp/ssh-argo-minion) read-only: `run` works, but bring-up/stop stay with
# start-minion-tunnel.sh -- an agent must not bounce the tunnel Minion depends on.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

resolve() {
    case "$1" in
        jlse)    HOST="login.jlse.anl.gov";   MODE="duo";   CP="/tmp/ssh-hermes-jlse" ;;
        aurora)  HOST="aurora.alcf.anl.gov";  MODE="otp";   CP="/tmp/ssh-hermes-aurora" ;;
        polaris) HOST="polaris.alcf.anl.gov"; MODE="otp";   CP="/tmp/ssh-hermes-polaris" ;;
        cels)    HOST="homes.cels.anl.gov";   MODE="reuse"; CP="/tmp/ssh-argo-minion" ;;
        *) echo "Unknown target: $1 (try: jlse aurora polaris cels)" >&2; exit 64 ;;
    esac
}

is_up() { ssh -O check -o ControlPath="${CP}" "${HOST}" 2>/dev/null; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "${cmd}" in
    targets|"")
        echo "jlse     login.jlse.anl.gov       Duo push"
        echo "aurora   aurora.alcf.anl.gov      MobilePASS passcode (stdin)"
        echo "polaris  polaris.alcf.anl.gov     MobilePASS passcode (stdin)"
        echo "cels     homes.cels.anl.gov       reuses production Minion master"
        exit 0 ;;

    status)
        resolve "${1:?target required}"
        if is_up; then echo "${1}: master up (${CP})"; exit 0
        else echo "${1}: master DOWN"; exit 1; fi ;;

    up)
        target="${1:?target required}"
        resolve "${target}"
        if [ "${MODE}" = "reuse" ]; then
            if is_up; then echo "cels: production master up (${CP})"; exit 0; fi
            echo "cels: production master is DOWN. Not starting it from here --" >&2
            echo "run ~/argo-shim-lite/start-minion-tunnel.sh (Duo push) instead." >&2
            exit 1
        fi
        if is_up; then echo "${target}: already up"; exit 0; fi
        # A dead socket file makes `ssh -M` refuse to create a new master.
        [ -S "${CP}" ] && rm -f "${CP}"

        secret=""
        if [ ! -t 0 ]; then IFS= read -r secret || true; fi
        if [ "${MODE}" = "otp" ] && [ -z "${secret}" ]; then
            echo "${target}: needs the current MobilePASS passcode on stdin:" >&2
            echo "  printf '%s\\n' <passcode> | $0 up ${target}" >&2
            exit 65
        fi

        echo "${target}: authenticating to ${HOST} (${MODE})..."
        REMOTE_MASTER_SECRET="${secret}" expect -f "${SCRIPT_DIR}/remote-master.exp" "${MODE}" \
            ssh -f -N -M \
                -o ControlPath="${CP}" -o ControlPersist=yes \
                -o StrictHostKeyChecking=accept-new \
                -o ServerAliveInterval=60 -o ServerAliveCountMax=10 \
                -o ConnectTimeout=30 \
                "${HOST}"
        rc=$?
        # expect exit 0 only means "reached eof" -- the socket is the truth.
        for _ in 1 2 3 4 5 6; do
            if is_up; then
                echo "${target}: master up (${CP})"
                # Carry Argo along: expose the mini's 8084 proxy on the remote's
                # localhost:18084, so remote claude needs NO tunnel of its own
                # (apps.inside.anl.gov is not reachable from these login nodes).
                # Non-fatal: the port may be taken on a shared login node.
                if ssh -O forward -R 127.0.0.1:18084:127.0.0.1:8084 \
                        -o ControlPath="${CP}" "${HOST}" 2>/dev/null; then
                    echo "${target}: Argo reverse-forwarded to remote localhost:18084"
                else
                    echo "${target}: could not add Argo reverse forward (remote port 18084 busy?)" >&2
                fi
                exit 0
            fi
            sleep 2
        done
        case "${rc}" in
            1) echo "${target}: permission denied (bad passcode/password?)" >&2 ;;
            2) echo "${target}: timed out waiting for auth (push not approved?)" >&2 ;;
            4) echo "${target}: push expired/denied or prompt re-printed" >&2 ;;
            6) echo "${target}: server asked for a secret this call did not have" >&2 ;;
            *) echo "${target}: master did not come up (expect rc=${rc})" >&2 ;;
        esac
        exit 1 ;;

    stop)
        resolve "${1:?target required}"
        if [ "${MODE}" = "reuse" ]; then
            echo "cels: refusing to stop the production Minion master." >&2; exit 1
        fi
        ssh -O stop -o ControlPath="${CP}" "${HOST}" 2>/dev/null && echo "${1}: stopped" || echo "${1}: was not up" ;;

    run)
        target="${1:?target required}"; shift
        resolve "${target}"
        if ! is_up; then
            echo "${target}: master is DOWN -- a human must authenticate first:" >&2
            case "${MODE}" in
                otp)   echo "  printf '%s\\n' <MobilePASS-code> | $0 up ${target}" >&2 ;;
                reuse) echo "  ~/argo-shim-lite/start-minion-tunnel.sh   (Duo push)" >&2 ;;
                *)     echo "  $0 up ${target}   (Duo push)" >&2 ;;
            esac
            exit 66
        fi
        # BatchMode: if the master ever vanishes mid-flight this fails fast
        # instead of hanging on an interactive prompt no one will answer.
        exec ssh -o ControlPath="${CP}" -o BatchMode=yes "${HOST}" "$@" ;;

    *) usage; exit 64 ;;
esac
