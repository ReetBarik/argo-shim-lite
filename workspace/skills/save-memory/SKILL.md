# Skill: Save Memory

## Trigger

When the user types `/remember`, "save memory", "checkpoint", or asks to update memory.

## Steps

1. Review the current session conversation from the top.

2. Identify what's worth persisting — ask: "would future-me benefit from knowing this?"
   - **Save:** decisions made (approach chosen over alternative), key findings, ongoing work
     with next steps, corrections to how Minion behaves, context specific to this setup
   - **Skip:** routine Q&A, transient info, things already in MEMORY.md, details that
     belong in a skill file rather than memory

3. Read MEMORY.md before writing — never duplicate an existing entry.

4. Write updates to the appropriate section:
   - **Decisions Made** — lasting choices with rationale
   - **Active Projects** — ongoing work, current status, next steps
   - **People** — collaborators, contacts, relevant context about them
   - **Infrastructure** — setup details, port maps, tooling decisions
   - **Completed** — finished work worth logging

5. Report what was saved as a bullet list, or say "nothing new worth saving" if the
   session had no lasting signal.

## Format rules

- One line per entry max — terse, no prose
- Include date for significant entries
- If uncertain whether something is worth saving, err toward skipping
