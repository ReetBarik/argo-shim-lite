# Operating rules (cost-efficiency)

These rules come from a measured retrospective of real usage: ~76% of one
day's token spend went to context re-processing (cache reads/rewrites), not
generated work, and most multi-agent review fan-outs confirmed rather than
corrected. Follow them by default; the user can override per-session.

## Orchestration scale

- Default to working solo or with at most 2-3 subagents. Reserve heavy
  multi-agent fan-outs (adversarial review panels, wide sweeps) for
  **freezing artifacts only**: public schemas/contracts, file formats, and
  plans that later sessions will execute unattended.
- Review designs before code exists; skip implementation-review fan-outs.
  Ordinary diffs get `/code-review` at medium effort (high if the diff
  touches numerics or parity-sensitive code).
- When spawning subagents: each returns a summary under 500 words to the
  main thread; details go to files. Never inject a multi-thousand-word
  agent report into the conversation.

## Session hygiene

- When a phase completes and its state is committed to files, the files ARE
  the state: offer the user a self-contained handoff prompt and recommend a
  fresh session instead of continuing in a large context.
- If context has grown past ~300K tokens, look for the next natural phase
  boundary and proactively suggest splitting there.
- Answer trivia and side questions briefly and directly — no exploration,
  no subagents. If the question is off-task and context is large, suggest a
  scratch session.
- Never do work belonging to a different repo inside this session; suggest
  a session in that repo instead.

## Escalation and de-escalation

- After two failed attempts at the same subgoal, or a numerical/parity
  mismatch that resists localization, recommend escalating (higher effort
  or `/model opus`) instead of grinding.
- If review gates keep confirming rather than correcting (two artifacts in
  a row rubber-stamped), say so and recommend lighter reviews or a lower
  tier for this kind of work.

## Long-running work

- For long builds/runs, use background execution and check results — don't
  poll in tight loops. State wait limits up front (e.g. "wait max 5 min for
  CI, then report and stop") rather than babysitting indefinitely.
- Keep tool output lean: tail/filter big logs instead of dumping them into
  context; they get re-read on every subsequent call.
