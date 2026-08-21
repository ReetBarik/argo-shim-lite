# OpenClaw + Argo Integration — Developer Notes

> Work in progress. Not ready for README.

## How to launch

```bash
~/argo-shim-lite/argonne-openclaw.sh [--identity=rbarik]
```

Sets up its own SSH tunnel (port 8085), starts the proxy (port 8084), and launches OpenClaw. No dependency on `argonne-claude.sh`.

## Architecture

```
openclaw TUI
    ↓
OpenClaw gateway (launchd, port 18789)
    ↓  ANTHROPIC_BASE_URL from gateway env
openclaw-argo-proxy.py  (port 8084)
    ↓  strips x-api-key, injects Authorization: Bearer <ARGO_USER>
SSH tunnel (port 8085 → apps.inside.anl.gov:443)
    ↓
Argo LLM API
```

## New files in argo-shim-lite/

| File | Purpose |
|------|---------|
| `openclaw-argo-proxy.py` | Proxy on 8084, forwards through tunnel on 8085, converts x-api-key → Bearer auth |
| `argonne-openclaw.sh` | Launcher: tunnel + proxy + openclaw |
| `report-ip.sh` | Posts the mini's primary IP to #openclaw on change/reboot, so you can reach it from home |

## launchd services

All are user agents in `gui/$(id -u)`, installed from `launchd/` into `~/Library/LaunchAgents/`.
Being *user* agents, they need `rbarik` to be logged in — they do not start at the login window.

| Label | Trigger | Does |
|-------|---------|------|
| `com.rbarik.minion-proxy` | RunAtLoad + KeepAlive | Runs `openclaw-argo-proxy.py` on 8084 |
| `com.rbarik.minion-tunnel` | On demand (`kickstart -k`) | Runs `tunnel-service.sh`: `ssh -N` under expect, answers Duo |
| `com.rbarik.minion-tunnel-check` | 8 AM–8 PM, every 2h | `tunnel-healthcheck.sh`: restarts the tunnel if down, alerts #openclaw |
| `com.rbarik.minion-ip-report` | RunAtLoad, every 15 min, on `/var/run/resolv.conf` change | `report-ip.sh`: posts the IP to #openclaw, but only when it changed |

## OpenClaw config changes

### `~/.openclaw/service-env/ai.openclaw.gateway.env`
Two lines added at the bottom:
```sh
export ANTHROPIC_BASE_URL='http://127.0.0.1:8084/argoapi/'
export ANTHROPIC_API_KEY='rbarik'
```

### `~/.openclaw/agents/main/auth-profiles.json`
```json
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "rbarik"
    }
  }
}
```

### `~/.openclaw/openclaw.json`
`models.providers.anthropic.baseUrl` is set but **has no effect** — see binary patch below.

## Binary patch ⚠️

OpenClaw's built-in Anthropic provider hardcodes `https://api.anthropic.com` with no config override path (`allowExplicitBaseUrl` is not set for the Anthropic provider).

**Patched file:** `/opt/homebrew/lib/node_modules/openclaw/dist/provider-stream-CIUub-IS.js`

In `resolveAnthropicMessagesUrl`, changed:
```js
// before
const normalized = (baseUrl?.trim() || "https://api.anthropic.com").replace(/\/+$/, "");
// after
const normalized = (baseUrl?.trim() || process.env.ANTHROPIC_BASE_URL || "https://api.anthropic.com").replace(/\/+$/, "");
```

**This patch is overwritten when openclaw updates.** To re-apply:
```bash
sed -i '' \
  's|baseUrl?.trim() || "https://api.anthropic.com"|baseUrl?.trim() || process.env.ANTHROPIC_BASE_URL || "https://api.anthropic.com"|' \
  /opt/homebrew/lib/node_modules/openclaw/dist/provider-stream-CIUub-IS.js
```

## Port map

| Port | Used by |
|------|---------|
| 8082 | `argonne-claude.sh` SSH tunnel (Claude Code) |
| 8083 | `claude-argo-proxy.py` (Claude Code) |
| 8084 | `openclaw-argo-proxy.py` (OpenClaw) |
| 8085 | `argonne-openclaw.sh` SSH tunnel (OpenClaw) |
