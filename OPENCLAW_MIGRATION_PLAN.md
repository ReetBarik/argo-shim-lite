# Migration Plan: minion.py → OpenClaw Native Discord

## Goal

Replace the custom `minion.py` Discord bot with OpenClaw's native Discord channel integration.
OpenClaw becomes the agent; Discord is its UI. Minion's bot token, Argo proxy, and SSH tunnel
infrastructure all carry over unchanged.

---

## Status (as of 2026-06-06)

| Phase | Status |
|---|---|
| Phase 0 — Resolve unknowns | ✅ Done |
| Phase 1 — Configure Discord integration | ✅ Done |
| Phase 2 — Bootstrap files | ✅ Done |
| Phase 3 — Skills | ✅ Done |
| Phase 4 — Cutover | ✅ Done (5/5 channels verified) |
| Phase 5 — Cleanup | ✅ Done |

**All phases complete.**

---

## Lessons learned / gotchas

- **Stale Discord token:** `openclaw.json` had an old hardcoded token. The live token is in
  `~/.minion-secrets`. Fixed by adding `DISCORD_TOKEN` to the gateway env file and switching
  to `{ source: "env", provider: "default", id: "DISCORD_TOKEN" }` in the config.

- **Skills not auto-loaded:** Skills in `workspace/skills/` are not injected into the agent's
  context automatically. The agent must be told they exist. Fixed by adding a skill registry
  table to `AGENTS.md`. In an existing session, tell Minion to "read your skills/X/SKILL.md"
  to load it on demand.

- **OpenClaw exec sandbox strips env vars:** `GITHUB_TOKEN` in the gateway env is not passed
  to exec subprocesses. Fixed by running `gh auth login --with-token` to store credentials in
  the system keyring. `gh` then authenticates without needing the env var.

- **`gh repo list` returns wrong repos:** With a fine-grained PAT, `gh repo list` only shows
  repos owned by the bot account (`ReetBarik-ai-minion`), not the repos Reet granted access to.
  Use `gh api /user/repos --jq '.[].full_name'` instead — this mirrors what the old PyGitHub
  `get_user().get_repos()` call did.

- **Guild ID typo in original plan:** Was `1509721937922752512`; correct ID is `1509721937922752532`.

---

## Current State

- `minion.py` bot is **stopped** (launchd service booted out, plist still on disk)
- OpenClaw gateway is live, Discord connected as @Minion in OpenClaw Lab
- All 4 skills deployed in `~/.openclaw/workspace/skills/`
- `gh` CLI installed, authenticated via keyring as `ReetBarik-ai-minion`

**Port map (unchanged):**
| Port | Service |
|------|---------|
| 8082 | Claude Code SSH tunnel |
| 8083 | claude-argo-proxy.py (Claude Code) |
| 8084 | hermes-argo-proxy.py (OpenClaw) |
| 8085 | OpenClaw SSH tunnel |

---

## Phase 0 — Resolve unknowns ✅

**Q1: PDF attachments** — OpenClaw docs list "documents in and out" and the Discord channel
docs show `{{MediaPath}}` / `{{MediaUrl}}` template vars for inbound files. Attachments are
downloaded to temp files and exposed to the agent. **Needs smoke test** — peer review is the
verification.

**Q2: Per-channel skill scoping** — Not supported natively. Skills are global across the guild.
Workaround: bake channel context into SKILL.md descriptions (e.g. "this skill is for
`#peer-review`") and let the agent self-select. Per-channel access control works via the
`channels` config in guilds.

**Q3: Workspace** — `agents.defaults.workspace` = `/Users/rbarik/.openclaw/workspace`. All
bootstrap files and skills live there.

---

## Phase 1 — Configure OpenClaw's Discord integration ✅

Config applied in `~/.openclaw/openclaw.json`:
- `channels.discord.token` → env reference to `DISCORD_TOKEN`
- `channels.discord.groupPolicy` → `allowlist`
- `channels.discord.guilds.1509721937922752532` → requireMention: false, users: ["737703362249621515"]

`DISCORD_TOKEN` and `GITHUB_TOKEN` added to `~/.openclaw/service-env/ai.openclaw.gateway.env`.

**Channel IDs for reference:**
| Channel | ID |
|---|---|
| #general | 1509721938396971162 |
| #openclaw | 1509722172787003603 |
| #literature-review | 1511179825010835466 |
| #code-development | 1511179911459635251 |
| #research-paper-peer-review | 1511180032838471681 |

---

## Phase 2 — Agent identity bootstrap files ✅

Written to `~/.openclaw/workspace/`:
- `SOUL.md` — Minion persona, channel map, Discord formatting rules, peer review format
- `USER.md` — Reet's background (HPC, parallel algorithms, Kokkos/SYCL/CUDA), preferences
- `AGENTS.md` — Skill registry table pointing to each SKILL.md + behavioral guidelines

---

## Phase 3 — Migrate tools as Skills ✅

All four skills created in `~/.openclaw/workspace/skills/`:

| Skill | Trigger | Notes |
|---|---|---|
| `tunnel/SKILL.md` | "tunnel" or `/tunnel` | Checks port 8085, execs start-minion-tunnel.sh |
| `github-ops/SKILL.md` | Any GitHub task | Uses `gh api /user/repos` (not `gh repo list`) |
| `literature-search/SKILL.md` | Paper search/fetch | curl-based: Semantic Scholar + arXiv |
| `peer-review/SKILL.md` | PDF upload in #peer-review | Uses `{{MediaPath}}` + literature.py extract |

---

## Phase 4 — Cutover ✅ (4/5 channels verified)

**Done:**
1. `launchctl bootout gui/$(id -u)/com.rbarik.minion-bot` — minion-bot stopped
2. Guild config applied and gateway restarted
3. Channels tested:
   - #general ✅
   - #openclaw ✅ (tunnel skill)
   - #literature-review ✅
   - #code-development ✅ (gh api, repo listing, permissions)
   - #research-paper-peer-review ✅ (chunked PDF review via Argo API)

**Peer review approach:** `{{MediaPath}}` is populated by OpenClaw for Discord attachments.
Native document block upload hits Argo's 1MB body limit for typical papers. Solution:
`tools/review_pdf.py` uses pikepdf to split into size-based chunks (≤700KB b64 each),
sends each chunk natively to Claude Opus 4.7 via `/v1/messages`, accumulates section
summaries, then synthesizes a structured HPC-lens review. No pdfplumber needed.

---

## Phase 5 — Remove obsolete infrastructure ✅

Once all 5 channels pass:

**1. Remove launchd plist:**
```bash
rm ~/Library/LaunchAgents/com.rbarik.minion-bot.plist
```

**2. Remove or archive from repo (`openclaw-argo` branch):**
- `minion.py` — delete
- `launch-minion.sh` — delete
- `tools/__init__.py` — delete
- `tools/github.py` — delete (replaced by `gh` CLI skill)
- `tools/literature.py` — **keep** — used by `literature-search/SKILL.md` (search/fetch tools)
- `tools/review_pdf.py` — **keep** — new file, used by `peer-review/SKILL.md` via exec
- `tools/web.py` — delete (agent uses curl directly)
- `launchd/com.rbarik.minion-bot.plist` — delete from repo

**3. What stays:**
- `hermes-argo-proxy.py` — still needed
- `com.rbarik.minion-proxy` launchd service — still needed
- `start-minion-tunnel.sh` — still needed (tunnel skill calls it)
- `launchd/com.rbarik.minion-proxy.plist` — still needed
- `tools/literature.py` — still needed (peer-review skill)

**4. Commit and push** on `openclaw-argo` branch.

---

## What carries over unchanged

| What | Status |
|---|---|
| Bot token (DISCORD_TOKEN) | In gateway env file, config uses env reference |
| GitHub PAT (GITHUB_TOKEN) | In gateway env file + gh keyring |
| `gh` CLI | Newly installed via brew, auth stored in keyring |
| Argo proxy on port 8084 | Unchanged |
| SSH tunnel on port 8085 | Unchanged |
| `start-minion-tunnel.sh` | Unchanged (called by tunnel skill) |
| Channel IDs, server ID | Same, now in OpenClaw config |
| Peer review system prompt | In `peer-review/SKILL.md` + `USER.md` |
