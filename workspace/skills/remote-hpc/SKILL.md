# Skill: /remote-hpc

## Trigger

When the user asks to run something on JLSE, Aurora, or Polaris; to check on a
remote job/build; or to run "remote claude" / argo-shim-lite Claude on an ANL
system. Also slash command `/remote-hpc <target> <command>`.

## What it does

Runs commands on ANL HPC systems over pre-authenticated SSH ControlMasters.
You (the agent) can USE a master but can never CREATE one — authentication is
Duo/MobilePASS and always goes through the human. Targets: `jlse`, `aurora`,
`polaris`, `cels`.

## Steps

1. Check the master:
   ```
   exec: ~/argo-shim-lite/remote-master.sh status <target>
   ```

2. If DOWN, ask the human in the channel and **stop — do not retry in a loop**:
   - jlse: "JLSE master is down. Run `~/argo-shim-lite/remote-master.sh up jlse` and approve the Duo push."
   - aurora/polaris: "Need a MobilePASS passcode. Run: `printf '%s\n' <code> | ~/argo-shim-lite/remote-master.sh up <target>`"
   - If the human posts a passcode in the channel, you may run that `up` command
     for them with the code on stdin (codes are single-use and expire in seconds).
   - cels: "Argo/Minion tunnel is down — run `~/argo-shim-lite/start-minion-tunnel.sh` and approve the push."

3. When UP, run the work:
   ```
   exec: ~/argo-shim-lite/remote-master.sh run <target> '<command>'
   ```
   This never prompts (BatchMode) — if it fails with "master is DOWN", go to step 2.

4. Remote Claude — needs NO extra auth or tunnel: `up` reverse-forwards the
   mini's Argo proxy to the remote's localhost:18084. Headless one-shot task
   (proven on jlselogin7):
   ```
   exec: ~/argo-shim-lite/remote-master.sh run <target> 'cd <workdir> && ANTHROPIC_BASE_URL=http://127.0.0.1:18084/argoapi/ ANTHROPIC_AUTH_TOKEN=rbarik CLAUDE_CODE_SKIP_ANTHROPIC_AUTH=1 ANTHROPIC_MODEL=claude-sonnet-4-5 ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5 ~/.local/bin/claude -p "<task>" --allowedTools Bash'
   ```
   Use canonical model names (claude-opus-5, claude-sonnet-4-5 ...), never
   Argo's squashed ids. Scope --allowedTools to what the task needs.
   If it errors with connection refused on 18084, the reverse forward is
   missing — re-run `up <target>` (no new auth needed while the master lives).

## Guardrails

- NEVER `remote-master.sh stop cels`, never touch `com.rbarik.minion-*`
  services, never open a second tunnel to homes.cels.anl.gov.
- Never ask the human for their password. Passcodes (OTP) in-channel are fine —
  single-use, expire in seconds. Passwords never.
- Long jobs: submit to the scheduler (`qsub`/PBS) and poll; don't hold an ssh
  exec open for hours.
- Keep remote work inside `~` on the remote unless told otherwise.

## Notes

- Masters persist until network drop, reboot, or explicit `stop` — one Duo
  push / one passcode can serve a whole day.
- Sockets: `/tmp/ssh-hermes-<target>`; cels reuses production `/tmp/ssh-argo-minion`.
- `remote-master.sh targets` lists everything.
