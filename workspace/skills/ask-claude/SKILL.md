# Skill: /ask-claude

## Trigger

When the user asks you to consult Claude, plan something "with Claude", continue
a planning discussion, or when a task needs deeper multi-step reasoning than
you want to do inline. Also slash command `/ask-claude [thread] <message>`.

## What it does

Talks to a shared, persistent Claude Code conversation ("thread"). The human
talks to the SAME thread from their terminal — Claude keeps one context for
both of you. Threads survive restarts; each is a named session backed by
Claude Code's resume mechanism, running against Argo through the local proxy.

## Steps

1. Pick the thread. Default to `planning` unless the user names one. List with:
   ```
   exec: ~/argo-shim-lite/claude-thread.sh threads
   ```

2. Send the message and capture the reply:
   ```
   exec: ~/argo-shim-lite/claude-thread.sh ask planning "<message>"
   ```
   When relaying on behalf of the user, prefix so Claude knows who is speaking:
   `[from Reet via Discord] <their message>` vs `[from Hermes] <your question>`.

3. Post Claude's reply to the channel. Attribute it: start with "Claude:" so
   nobody mistakes whose words they are.

4. If it fails with "thread is busy", another turn is in flight — wait ~30s and
   retry once, then tell the user.
   If it fails with "no parseable output", check the proxy/tunnel:
   `exec: lsof -i :8084 -sTCP:LISTEN` and the /tunnel (or remote-hpc cels) flow.

## Guardrails

- Turn-based, one message at a time — never fire parallel asks at one thread.
- Don't relay an endless back-and-forth on your own initiative: one ask, one
  reply, then let the human steer. You are the gateway, not a proxy war.
- Keep threads topical (`planning`, `paper-review`, ...) instead of one giant
  thread; tell the user which thread you used.
- If Claude's reply asks for something to be EXECUTED (run code, change infra),
  bring it back to the human first — Claude plans, the human approves, you or
  remote-hpc execute.
- If Argo's Opus tier hangs or 502s, retry once with
  `CLAUDE_THREAD_MODEL=claude-sonnet-5` prefixed to the exec.

## Notes

- Thread state: `~/.claude-threads/<name>.id`; threads run in
  `~/.claude-threads/workspace`, not in any live repo.
- The human can join interactively: `~/argo-shim-lite/claude-thread.sh attach <name>`
  (but not while an ask is in flight).
