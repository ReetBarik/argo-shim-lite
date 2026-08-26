#!/bin/bash
# Fan out secrets from ~/.minion-secrets to every live consumer.
# Edit ~/.minion-secrets, then run this script.
#
# Rewritten Aug 2026 for the Hermes-only stack. The previous version targeted
# ~/.openclaw/service-env/ and kickstarted ai.openclaw.gateway; both are gone,
# so with `set -e` it died partway AFTER already rewriting files -- succeeding
# silently and then reporting failure.
#
# WHAT CHANGED, AND ONE THING TO KNOW:
#   Hermes runs a DIFFERENT Discord bot identity than Minion/OpenClaw did.
#   ~/.minion-secrets:DISCORD_TOKEN is the *Minion* bot; Hermes uses
#   DISCORD_BOT_TOKEN in ~/.hermes/.env. They are deliberately distinct, so
#   this script keeps them in separate variables rather than assuming one
#   token fans out to both. Set HERMES_DISCORD_TOKEN in ~/.minion-secrets if
#   you want this script to manage the Hermes token too; if it is unset, the
#   Hermes token is left untouched.
#
# This script does NOT restart the gateway. Restarts are the human's call --
# the gateway blocks self-restart, and a secrets refresh does not always need
# one. It tells you when a restart is required.

set -euo pipefail

SECRETS="$HOME/.minion-secrets"
HERMES_ENV="$HOME/.hermes/.env"

[ -f "$SECRETS" ] || { echo "error: $SECRETS not found" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SECRETS"

restart_needed=0

# --- Hermes gateway Discord token -----------------------------------------
# Only touched when explicitly provided, so a stale Minion token can never
# silently overwrite the working Hermes one.
if [ -n "${HERMES_DISCORD_TOKEN:-}" ]; then
    if [ ! -f "$HERMES_ENV" ]; then
        echo "error: $HERMES_ENV not found" >&2; exit 1
    fi
    current=$(grep -E '^DISCORD_BOT_TOKEN=' "$HERMES_ENV" | head -1 | cut -d= -f2- || true)
    if [ "$current" != "$HERMES_DISCORD_TOKEN" ]; then
        # No quotes: Hermes' .env parser takes the raw value, and stray quote
        # characters end up embedded in the token (Discord then 401s).
        sed -i '' "s|^DISCORD_BOT_TOKEN=.*|DISCORD_BOT_TOKEN=${HERMES_DISCORD_TOKEN}|" "$HERMES_ENV"
        echo "updated  DISCORD_BOT_TOKEN in ~/.hermes/.env"
        restart_needed=1
    else
        echo "unchanged DISCORD_BOT_TOKEN"
    fi
else
    echo "skipped  DISCORD_BOT_TOKEN (HERMES_DISCORD_TOKEN not set in ~/.minion-secrets)"
fi

# --- GitHub CLI ------------------------------------------------------------
# gh stores its own credential; re-auth is idempotent and takes effect
# immediately, no restart required.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    _t="$GITHUB_TOKEN"
    unset GITHUB_TOKEN          # gh refuses to log in while this is exported
    if printf '%s' "$_t" | gh auth login --with-token 2>/dev/null; then
        echo "updated  gh auth ($(gh api user --jq .login 2>/dev/null || echo 'unknown'))"
    else
        echo "WARNING  gh auth login failed" >&2
    fi
fi

# --- ARGO_USER -------------------------------------------------------------
# Consumed by hermes-argo-proxy.py to build the Bearer header. It is set in
# the launchd plist, not read from this file, so changing it here is not
# enough -- say so rather than pretending it propagated.
if [ -n "${ARGO_USER:-}" ]; then
    plist="$HOME/Library/LaunchAgents/com.rbarik.minion-proxy.plist"
    live=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:ARGO_USER" "$plist" 2>/dev/null || echo "")
    if [ "$live" != "$ARGO_USER" ]; then
        echo "MISMATCH ARGO_USER: secrets='${ARGO_USER}' but plist='${live}'"
        echo "         edit $plist and reload com.rbarik.minion-proxy (see below)"
    else
        echo "unchanged ARGO_USER (${ARGO_USER})"
    fi
fi

echo
if [ "$restart_needed" -eq 1 ]; then
    cat <<'EOF'
A gateway restart is required for the new token to take effect.
Run this from a PLAIN TERMINAL (not inside a Hermes session):

    hermes gateway restart

If you instead changed the proxy plist, reload it with a POLLED teardown --
`bootout; bootstrap` on one line races the still-registered label and leaves
the service unloaded:

    launchctl bootout gui/$(id -u)/com.rbarik.minion-proxy
    while launchctl print gui/$(id -u)/com.rbarik.minion-proxy >/dev/null 2>&1; do sleep 0.25; done
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.rbarik.minion-proxy.plist
EOF
else
    echo "Done. No restart required."
fi
