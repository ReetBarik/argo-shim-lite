# Skill: /tunnel

## Trigger

Slash command `/tunnel` in any channel, or when the user asks to start, restart, or check the SSH tunnel.

## What it does

Checks whether the Argo SSH tunnel is up, and starts it if not.

## Steps

1. Check if port 8085 is listening:
   ```
   exec: lsof -i :8085 -sTCP:LISTEN
   ```
   If output is non-empty, tunnel is already up — report back and stop.

2. If port 8085 is not listening, start the tunnel:
   ```
   exec: ~/argo-shim-lite/start-minion-tunnel.sh
   ```

3. Wait ~3 seconds, then re-check port 8085 to confirm it came up.

4. Report result to the channel:
   - Success: "Tunnel up on port 8085."
   - Failure: "Tunnel failed to start — check `~/.openclaw/logs/` for details."

## Notes

- The tunnel is required for the Argo LLM proxy (port 8084) to reach ANL.
- If the proxy itself is down, check `launchctl list | grep minion`.
