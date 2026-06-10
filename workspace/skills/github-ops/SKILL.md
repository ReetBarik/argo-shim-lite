# Skill: GitHub Operations

## When to use

When the user asks to read or write GitHub repositories, create issues or PRs, review code,
or do anything GitHub-related. Primarily in **#code-development**, but available everywhere.

## Tools

Use the `gh` CLI for all GitHub operations. Auth is stored in the system keyring — no env var needed.

## Common operations

**List repos the token has access to:**
```
exec: gh api /user/repos --jq '.[].full_name'
```
(Do NOT use `gh repo list` — it only shows repos owned by the bot account, not the repos Reet granted access to.)

**Read a file:**
```
exec: gh api repos/OWNER/REPO/contents/PATH --jq '.content' | base64 -d
```

**Create an issue:**
```
exec: gh issue create --repo OWNER/REPO --title "..." --body "..."
```

**Create a PR:**
```
exec: gh pr create --repo OWNER/REPO --title "..." --body "..." --base main --head BRANCH
```

**View PR / issue:**
```
exec: gh pr view NUMBER --repo OWNER/REPO
exec: gh issue view NUMBER --repo OWNER/REPO
```

## Rules

- **Always confirm before write operations** (create issue, create PR, push, merge, delete).
- Read operations (list, view, read file) can proceed without confirmation.
- When in doubt, show the user what you're about to run and ask.
