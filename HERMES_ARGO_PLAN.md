# Hermes + Argo on the Mac mini — Execution Plan

**Goal:** stand up Hermes Agent against Argo on the Mac mini, running *alongside* the
live OpenClaw/Minion setup, without touching it.

**Non-goals (deliberately out of scope):**
- Migrating or retiring OpenClaw. It keeps running throughout.
- ALCF Inference Service / Globus / `alcf-agent-box`. Argo stays the backend.
- Docker. Hermes installs natively, matching how OpenClaw is deployed here.

**Where this runs:** the office Mac mini (Apple Silicon, `/opt/homebrew`, launchd).
Not Aurora, not a cluster login node.

---

## Prime directive: additive only

Every step below **adds** files, ports, launchd labels, and Discord identities.
Nothing modifies a file OpenClaw reads or a service it depends on. If you find
yourself editing `hermes-argo-proxy.py`, `~/.openclaw/*`, `~/.minion-secrets`,
or any `com.rbarik.minion-*` plist — stop, you've left the plan.

Rollback at any point is: stop the new thing. OpenClaw never knew.

### Do not touch

| Thing | Why |
|---|---|
| `~/.openclaw/**` | OpenClaw's live config, workspace, auth profiles |
| `~/.minion-secrets` | Minion's Discord token — Hermes gets its **own** |
| `com.rbarik.minion-proxy` / `-tunnel` / `-tunnel-check` | Live services |
| Ports 8084, 8085, 18789 | In use (see port map) |
| `brew upgrade` / `npm -g update` | Would wipe the OpenClaw Anthropic binary patch (see `OPENCLAW_NOTES.md`). Don't run these during this work. |

### Port map

| Port | Owner | Status |
|---|---|---|
| 8084 | `hermes-argo-proxy.py` (OpenClaw) | existing — **read-only use in Phase 0–4** |
| 8085 | SSH tunnel → `apps.inside.anl.gov:443` | existing — **shared, do not open a second one** |
| 18789 | OpenClaw gateway | existing |
| 8086 | `hermes-argo-proxy.py` | new, Phase 5 |

The tunnel on 8085 is the scarce resource — it costs a Duo tap and is the thing
the watchdog exists to babysit. One tunnel, two proxies. Never a second tunnel.

---

## Phase 0 — Recon: what dialect does Argo actually speak?

No installs. ~15 minutes. This gates everything else.

```bash
cd ~/argo-shim-lite   # or wherever the clone lives

# 1. Is the shared tunnel up?
ssh -O check -o ControlPath=/tmp/ssh-argo-minion homes.cels.anl.gov
# If not: ./start-minion-tunnel.sh   (approve the Duo push on your phone)

# 2. What models does Argo list?
curl -s http://127.0.0.1:8084/argoapi/v1/models | head -c 1000; echo

# 3. Does it serve OpenAI Chat Completions?
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8084/argoapi/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<pick-one-from-step-2>","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'

# 4. Does it serve Anthropic Messages? (this one we know works — Claude Code uses it)
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8084/argoapi/v1/messages \
  -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"<pick-one>","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'
```

Note: the 8084 proxy injects `Authorization: Bearer $ARGO_USER` itself and strips
`x-api-key`, so these curls need no auth header. That convenience goes away in
Phase 5 when Hermes gets its own proxy.

**Record the result here before continuing:**

- [ ] `/v1/models` returns a catalog — model ids seen: `____`
- [ ] `/v1/chat/completions` → HTTP `____`
- [ ] `/v1/messages` → HTTP `____`

**Gate:** at least one of the two POST endpoints returns 200.
- Both work → prefer OpenAI dialect in Phase 2 (Hermes' best-supported path).
- Only Messages works → use Hermes' `anthropic` provider type in Phase 2.
- Neither works → stop. Fall back to `oaklight/argo-proxy` as a translating
  replacement and re-run Phase 0 against it. Do not proceed on a broken backend.

---

## Phase 1 — Install Hermes (no config yet)

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
hermes --version
```

The installer pulls uv, Python 3.11, Node, ripgrep, ffmpeg. It should create
`~/.hermes`. Verify it did **not** write anything under `~/.openclaw`:

```bash
ls -la ~/.hermes
find ~/.openclaw -newermt '-10 minutes' 2>/dev/null   # expect: empty
```

**Gate:** `hermes --version` works and `~/.openclaw` is untouched.

**Rollback:** remove `~/.hermes` and whatever the installer put on PATH.

---

## Phase 2 — Wire Hermes to Argo, TUI only

Config goes in `~/.hermes/config.yaml`; the key goes in `~/.hermes/.env`.
Confirm the exact schema against the live docs before writing —
<https://hermes-agent.nousresearch.com/docs/integrations/providers> — the shape
below is from those docs but verify field names rather than trusting this file.

**If Phase 0 said OpenAI dialect:**

```yaml
# ~/.hermes/config.yaml
models:
  providers:
    argo:
      type: openai
      base_url: http://127.0.0.1:8084/argoapi/v1
      key_env: ARGO_API_KEY
      models:
        - <model-id-from-phase-0>
```

```bash
# ~/.hermes/.env
ARGO_API_KEY=rbarik      # Argo identity, not a secret — SSH+MFA is the real gate
```

**If Phase 0 said Anthropic-only:** use Hermes' `anthropic` provider type with
the same `base_url`, or install `argo-proxy` on a new port and point at that.

Then, interactively:

```bash
hermes
```

Three escalating checks, in order:

1. Plain chat — does it answer at all?
2. Tool call — "read `~/argo-shim-lite/README.md` and tell me the two backends."
3. Multi-step — "list the files in this repo, then summarize what `pick-models.py` does."

**Gate:** step 3 completes. Tool-calling through Argo is the whole question; chat
working proves nothing. If tool calls fail, check whether Argo's tool-call format
survives the round trip before blaming Hermes — that's the exact class of bug
`alcf-agent-box` had to patch for its gateway.

**Rollback:** delete `~/.hermes/config.yaml`. Nothing else was touched.

---

## Phase 3 — Port skills (still no Discord)

Hermes gets its **own** workspace. Do not point it at `~/.openclaw/workspace`.

```bash
mkdir -p ~/hermes-workspace/skills
cp -r ~/.openclaw/workspace/skills/github-ops        ~/hermes-workspace/skills/
cp -r ~/.openclaw/workspace/skills/literature-search ~/hermes-workspace/skills/
cp -r ~/.openclaw/workspace/skills/peer-review       ~/hermes-workspace/skills/
cp -r ~/.openclaw/workspace/skills/save-memory       ~/hermes-workspace/skills/
# tools the skills call
cp ~/argo-shim-lite/tools/literature.py  ~/hermes-workspace/
cp ~/argo-shim-lite/tools/review_pdf.py  ~/hermes-workspace/
```

**Deliberately skipping the `tunnel` skill.** It runs
`launchctl kickstart com.rbarik.minion-tunnel` — an experimental agent must not be
able to bounce the service the production one depends on. Add it back only after
Hermes is the primary.

Copy, don't symlink: a symlink lets Hermes' skill self-improvement loop rewrite
Minion's live skills.

Then test the workload that actually matters:

> Run `peer-review` against a real PDF you've already had Minion review, and
> compare the output.

**Gate:** skills load, and peer-review produces something you'd accept. This is
where model quality shows up, not in Phase 2.

**Note on `gh`:** it's authenticated in the system keyring as
`ReetBarik-ai-minion`, so Hermes inherits Minion's GitHub identity. During the
trial, keep Hermes' GitHub use read-only — two agents writing as the same
identity is confusing to untangle.

---

## Phase 4 — Second Discord bot

**This is the step most likely to cause visible damage if rushed.** Same token
in the same guild = both bots answer every message and react to each other.

Manual, in the Discord developer portal:

1. New Application → e.g. `Minion-Hermes` → Bot → copy token.
2. Invite it to a **test guild**, or to a channel in OpenClaw Lab that @Minion
   cannot see. Do not put it in `#openclaw`, `#peer-review`, or any channel
   Minion currently serves.
3. Put the token in `~/.hermes/.env` — **never** in `~/.minion-secrets`.
4. Enable Hermes' Discord channel in `~/.hermes/config.yaml`.

Verify explicitly:

- [ ] Message the test channel → only Hermes replies
- [ ] Message `#peer-review` → only Minion replies
- [ ] Neither bot appears in the other's channel list

**Gate:** all three confirmed. If Minion so much as sees a Hermes message,
back out the invite and redo the channel permissions.

**Rollback:** kick the new bot from the guild.

---

## Phase 5 — Persist, and cut the dependency on OpenClaw's proxy

Until now Hermes has been borrowing `com.rbarik.minion-proxy` on 8084. That
means stopping Minion breaks Hermes. Give Hermes its own proxy on 8086, still
pointed at the **shared** 8085 tunnel.

`main` already has an env-parameterized pass-through — take it rather than
writing a third copy:

```bash
cd ~/argo-shim-lite
git show fork/main:claude-argo-proxy.py > hermes-argo-proxy.py

ARGO_PROXY_LISTEN_PORT=8086 \
ARGO_PROXY_TARGET_PORT=8085 \
python3 hermes-argo-proxy.py
```

That version does *not* inject the Bearer header — Hermes supplies its own auth
from `ARGO_API_KEY`, which is why this works. Confirm with a curl against 8086,
then repoint `base_url` in `~/.hermes/config.yaml` from 8084 → 8086.

launchd services, modeled on the `com.rbarik.minion-*` plists in `launchd/`:

- `com.rbarik.hermes-proxy` — runs `hermes-argo-proxy.py` on 8086
- `com.rbarik.hermes-gateway` — runs the Hermes gateway

**Do not create a `com.rbarik.hermes-tunnel`.** The tunnel is shared; a second
Duo-gated `ssh -N` doubles the failure surface and can push-storm.

**Gate:** `launchctl bootout` the OpenClaw proxy briefly — Hermes keeps working.
Then boot it back in. (Do this at a quiet hour; it interrupts Minion.)

---

## Decision point (after Phase 5)

Run both for a week, then decide:

- **Hermes wins** → cleanup commit removing OpenClaw files, refactor the two
  near-identical proxies into one parameterized service, add back the `tunnel`
  skill, retire `com.rbarik.minion-*`, merge to `main`.
- **Hermes loses** → `git branch -D hermes-argo`, `launchctl bootout` the two
  hermes labels, `rm -rf ~/.hermes ~/hermes-workspace`, kick the bot. Nothing
  else to undo.
- **Revisit later:** `alcf-agent-box`'s `alcf-pbs` and `alcf-iri-facility-api`
  skills are useful regardless of which model is behind them, and don't require
  adopting ALCF inference. Worth harvesting once Hermes is stable.

---

## Open questions — fill in during execution

| # | Question | Answer |
|---|---|---|
| 1 | Which API dialect does Argo serve? (Phase 0) | |
| 2 | Exact Hermes provider YAML schema — does the doc match this plan? | |
| 3 | Does tool-calling survive the Argo round trip? (Phase 2) | |
| 4 | Is Argo's model quality via Hermes comparable to Minion's today? (Phase 3) | |
| 5 | Which Hermes ports does the gateway bind? Any collision with 18789? | |

---

## Handoff note

If you run this with a fresh Claude session on the Mac mini, that session should
read this file first and work phase by phase, stopping at each **Gate**. The
gates are where a bad result should halt the work rather than get worked around
— particularly Phase 0 (broken backend) and Phase 4 (bot crosstalk).
