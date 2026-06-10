# Skill: Literature Search

## When to use

When the user asks to find papers, search for research, fetch an arXiv paper, or summarize
literature. Primarily in **#literature-review**, but available everywhere.

## Sources

### Semantic Scholar

Search for papers:
```
exec: curl -s "https://api.semanticscholar.org/graph/v1/paper/search?query=QUERY&limit=5&fields=title,authors,year,abstract,externalIds" | python3 -m json.tool
```

Fetch a specific paper by ID:
```
exec: curl -s "https://api.semanticscholar.org/graph/v1/paper/PAPER_ID?fields=title,authors,year,abstract,tldr,externalIds"
```

### arXiv

Fetch paper metadata by arXiv ID (e.g. `2401.12345`):
```
exec: curl -s "https://export.arxiv.org/abs/ARXIV_ID"
```

Download PDF:
```
exec: curl -L "https://arxiv.org/pdf/ARXIV_ID.pdf" -o /tmp/paper.pdf
```

Extract text from a downloaded PDF:
```
exec: python3 ~/argo-shim-lite/tools/literature.py extract /tmp/paper.pdf
```

## Output format

- Always cite: title, authors, year, venue/source
- For summaries: one paragraph high-level, then key contributions as bullets
- When comparing multiple papers: group by theme, not chronologically
- Wrap arXiv/S2 URLs in `<>` to suppress Discord embeds
