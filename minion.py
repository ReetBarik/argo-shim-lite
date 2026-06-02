#!/usr/bin/env python3
"""
Minion — AI intern Discord bot routed through the Argo LLM backend.

Required environment variables:
  DISCORD_TOKEN   Bot token from Discord Developer Portal
  GITHUB_TOKEN    Fine-grained PAT for ReetBarik-ai-minion
  ARGO_USER       ANL username (used as Bearer token by the proxy)

Optional:
  ARGO_MODEL      Claude model ID (default: claude-sonnet-4-5-20251001)
  PROXY_URL       Argo proxy base URL (default: http://127.0.0.1:8084/argoapi/)
"""

import asyncio
import io
import os
import re
import textwrap

import discord
import httpx
import pdfplumber
from anthropic import AsyncAnthropic
from bs4 import BeautifulSoup
from github import Auth, Github, GithubException

# ── Configuration ─────────────────────────────────────────────────────────────

DISCORD_TOKEN = os.environ["DISCORD_TOKEN"]
GITHUB_TOKEN  = os.environ["GITHUB_TOKEN"]
ARGO_USER     = os.environ.get("ARGO_USER", os.environ.get("USER", "minion"))
PROXY_URL     = os.environ.get("PROXY_URL", "http://127.0.0.1:8084/argoapi/")
MODEL         = os.environ.get("ARGO_MODEL", "claude-sonnet-4-5-20251001")

MAX_HISTORY   = 30   # messages per channel kept in memory
MAX_TOOL_ROUNDS = 10 # max agentic iterations before giving up

# Channel IDs → focus description fed into the system prompt
CHANNEL_FOCUS: dict[int, str] = {
    1509721938396971162: "general assistant — answer questions, help with any task",
    1509722172787003603: "OpenClaw and Claude Code tooling — configuration, debugging, and usage",
    1511179825010835466: "literature search and paper analysis — use Semantic Scholar and arXiv, summarize findings, compare papers",
    1511179911459635251: "code and GitHub tasks — read and write files, create issues and PRs, review code",
    1511180032838471681: "peer review of research papers — critically evaluate methodology, results, clarity, and novelty",
}

# ── Clients ───────────────────────────────────────────────────────────────────

llm = AsyncAnthropic(base_url=PROXY_URL, api_key=ARGO_USER)
gh  = Github(auth=Auth.Token(GITHUB_TOKEN))

intents = discord.Intents.default()
intents.message_content = True
bot = discord.Client(intents=intents)

# Per-channel conversation history: channel_id -> [{"role": ..., "content": ...}]
history: dict[int, list[dict]] = {}

# ── Tool definitions ──────────────────────────────────────────────────────────

TOOLS = [
    {
        "name": "search_literature",
        "description": (
            "Search academic papers via Semantic Scholar. "
            "Returns titles, authors, year, abstract snippet, and link."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "default": 5},
            },
            "required": ["query"],
        },
    },
    {
        "name": "fetch_arxiv_paper",
        "description": "Fetch an arXiv paper by ID (e.g. 2301.07041) or full arXiv URL. Returns title, authors, and abstract.",
        "input_schema": {
            "type": "object",
            "properties": {
                "paper_id": {"type": "string", "description": "arXiv ID or URL"},
            },
            "required": ["paper_id"],
        },
    },
    {
        "name": "fetch_pdf",
        "description": "Download and extract text from a PDF at a given URL.",
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
                "max_pages": {"type": "integer", "default": 10},
            },
            "required": ["url"],
        },
    },
    {
        "name": "fetch_url",
        "description": "Fetch and parse a webpage. Returns the main text content.",
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "github_read_file",
        "description": "Read a file from a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":  {"type": "string", "description": "owner/repo"},
                "path":  {"type": "string", "description": "File path in repo"},
                "ref":   {"type": "string", "description": "Branch, tag, or SHA (optional)"},
            },
            "required": ["repo", "path"],
        },
    },
    {
        "name": "github_list_files",
        "description": "List files and directories at a path in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo"},
                "path": {"type": "string", "description": "Directory path (default: root)", "default": ""},
                "ref":  {"type": "string", "description": "Branch, tag, or SHA (optional)"},
            },
            "required": ["repo"],
        },
    },
    {
        "name": "github_write_file",
        "description": "Create or update a file in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":    {"type": "string", "description": "owner/repo"},
                "path":    {"type": "string"},
                "content": {"type": "string", "description": "Full file content"},
                "message": {"type": "string", "description": "Commit message"},
                "branch":  {"type": "string", "description": "Target branch (optional, defaults to repo default)"},
            },
            "required": ["repo", "path", "content", "message"],
        },
    },
    {
        "name": "github_create_issue",
        "description": "Create an issue in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":   {"type": "string", "description": "owner/repo"},
                "title":  {"type": "string"},
                "body":   {"type": "string"},
                "labels": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["repo", "title", "body"],
        },
    },
    {
        "name": "github_create_pr",
        "description": "Create a pull request in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":  {"type": "string", "description": "owner/repo"},
                "title": {"type": "string"},
                "body":  {"type": "string"},
                "head":  {"type": "string", "description": "Branch with changes"},
                "base":  {"type": "string", "description": "Target branch (optional, defaults to repo default)"},
            },
            "required": ["repo", "title", "body", "head"],
        },
    },
]

# ── Tool implementations ──────────────────────────────────────────────────────

async def search_literature(query: str, limit: int = 5) -> str:
    params = {
        "query": query,
        "limit": limit,
        "fields": "title,authors,year,abstract,url,externalIds",
    }
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            "https://api.semanticscholar.org/graph/v1/paper/search",
            params=params,
            timeout=20,
        )
    papers = resp.json().get("data", [])
    if not papers:
        return "No papers found."

    out = []
    for p in papers:
        authors = ", ".join(a["name"] for a in p.get("authors", [])[:3])
        arxiv_id = p.get("externalIds", {}).get("ArXiv", "")
        link = f"https://arxiv.org/abs/{arxiv_id}" if arxiv_id else p.get("url", "")
        abstract = (p.get("abstract") or "")[:300]
        out.append(f"**{p['title']}** ({p.get('year','?')})\n{authors}\n{abstract}...\n{link}")
    return "\n\n---\n\n".join(out)


async def fetch_arxiv_paper(paper_id: str) -> str:
    arxiv_id = re.sub(r".*arxiv\.org/(?:abs|pdf)/", "", paper_id).replace(".pdf", "").strip()
    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(f"https://arxiv.org/abs/{arxiv_id}", timeout=15)
    soup = BeautifulSoup(resp.text, "html.parser")

    title = soup.find("h1", class_="title")
    title = title.get_text(strip=True).replace("Title:", "").strip() if title else "Unknown"

    authors_tag = soup.find("div", class_="authors")
    authors = authors_tag.get_text(strip=True).replace("Authors:", "").strip() if authors_tag else "Unknown"

    abstract_tag = soup.find("blockquote", class_="abstract")
    abstract = abstract_tag.get_text(strip=True).replace("Abstract:", "").strip() if abstract_tag else "Not found"

    return f"**{title}**\nAuthors: {authors}\n\nAbstract: {abstract}\n\nPDF: https://arxiv.org/pdf/{arxiv_id}"


async def fetch_pdf(url: str, max_pages: int = 10) -> str:
    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(url, timeout=30)
    with pdfplumber.open(io.BytesIO(resp.content)) as pdf:
        text = "\n\n".join(p.extract_text() or "" for p in pdf.pages[:max_pages])
    return text[:8000] if text.strip() else "Could not extract text from PDF."


async def fetch_url(url: str) -> str:
    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(url, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["script", "style", "nav", "footer", "header"]):
        tag.decompose()
    return soup.get_text(separator="\n", strip=True)[:6000]


def _github_read_file(repo: str, path: str, ref: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"ref": ref} if ref else {}
    content = r.get_contents(path, **kwargs)
    return content.decoded_content.decode()


def _github_list_files(repo: str, path: str = "", ref: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"ref": ref} if ref else {}
    contents = r.get_contents(path, **kwargs)
    lines = [f"{'[dir] ' if c.type == 'dir' else '[file]'} {c.path}" for c in contents]
    return "\n".join(lines)


def _github_write_file(repo: str, path: str, content: str, message: str, branch: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"branch": branch} if branch else {}
    try:
        existing = r.get_contents(path, **kwargs)
        r.update_file(path, message, content, existing.sha, **kwargs)
        return f"Updated `{path}` in {repo}"
    except GithubException:
        r.create_file(path, message, content, **kwargs)
        return f"Created `{path}` in {repo}"


def _github_create_issue(repo: str, title: str, body: str, labels: list = None) -> str:
    r = gh.get_repo(repo)
    issue = r.create_issue(title=title, body=body, labels=labels or [])
    return f"Created issue #{issue.number}: {issue.html_url}"


def _github_create_pr(repo: str, title: str, body: str, head: str, base: str = None) -> str:
    r = gh.get_repo(repo)
    base = base or r.default_branch
    pr = r.create_pull(title=title, body=body, head=head, base=base)
    return f"Created PR #{pr.number}: {pr.html_url}"


async def execute_tool(name: str, inputs: dict) -> str:
    try:
        if name == "search_literature":
            return await search_literature(**inputs)
        if name == "fetch_arxiv_paper":
            return await fetch_arxiv_paper(**inputs)
        if name == "fetch_pdf":
            return await fetch_pdf(**inputs)
        if name == "fetch_url":
            return await fetch_url(**inputs)
        # GitHub calls are sync (PyGithub); run in thread to avoid blocking the event loop
        if name == "github_read_file":
            return await asyncio.to_thread(_github_read_file, **inputs)
        if name == "github_list_files":
            return await asyncio.to_thread(_github_list_files, **inputs)
        if name == "github_write_file":
            return await asyncio.to_thread(_github_write_file, **inputs)
        if name == "github_create_issue":
            return await asyncio.to_thread(_github_create_issue, **inputs)
        if name == "github_create_pr":
            return await asyncio.to_thread(_github_create_pr, **inputs)
        return f"Unknown tool: {name}"
    except Exception as exc:
        return f"Tool error ({name}): {exc}"

# ── Agent loop ────────────────────────────────────────────────────────────────

def _system_prompt(channel_id: int) -> str:
    focus = CHANNEL_FOCUS.get(channel_id, "general assistant")
    return (
        "You are Minion, an AI research assistant and software engineering intern "
        "working for Reet Barik. You run on a Mac mini and are accessed via Discord.\n\n"
        f"Current channel focus: {focus}\n\n"
        "Guidelines:\n"
        "- Be concise — Discord messages should be scannable, not walls of text\n"
        "- Use code blocks for code, bullet points for lists\n"
        "- For long outputs (papers, file contents), summarize and offer to share more on request\n"
        "- When using GitHub write tools, confirm the action briefly before executing\n"
        "- Cite sources when doing literature work"
    )


async def run_agent(channel_id: int, user_message: str) -> str:
    ch_history = history.setdefault(channel_id, [])
    ch_history.append({"role": "user", "content": user_message})

    if len(ch_history) > MAX_HISTORY:
        ch_history[:] = ch_history[-MAX_HISTORY:]

    messages = list(ch_history)

    for _ in range(MAX_TOOL_ROUNDS):
        response = await llm.messages.create(
            model=MODEL,
            max_tokens=4096,
            system=_system_prompt(channel_id),
            tools=TOOLS,
            messages=messages,
        )

        if response.stop_reason == "end_turn":
            text = next((b.text for b in response.content if hasattr(b, "text")), "")
            ch_history.append({"role": "assistant", "content": text})
            return text

        if response.stop_reason == "tool_use":
            messages.append({"role": "assistant", "content": response.content})
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    result = await execute_tool(block.name, block.input)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result,
                    })
            messages.append({"role": "user", "content": tool_results})
            continue

        break

    return "I ran into trouble completing that — try rephrasing or breaking it into smaller steps."

# ── Discord events ────────────────────────────────────────────────────────────

def _split(text: str, limit: int = 1900) -> list[str]:
    if len(text) <= limit:
        return [text]
    parts = []
    while text:
        if len(text) <= limit:
            parts.append(text)
            break
        cut = text.rfind("\n", 0, limit)
        if cut == -1:
            cut = limit
        parts.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return parts


@bot.event
async def on_ready():
    print(f"Minion online as {bot.user} (model: {MODEL})")


@bot.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return
    if message.channel.id not in CHANNEL_FOCUS:
        return

    # !clear resets conversation history for the channel
    if message.content.strip() == "!clear":
        history.pop(message.channel.id, None)
        await message.channel.send("Conversation history cleared.")
        return

    async with message.channel.typing():
        try:
            reply = await run_agent(message.channel.id, message.content)
        except Exception as exc:
            await message.channel.send(f"⚠️ Error: {exc}")
            return

    for chunk in _split(reply):
        await message.channel.send(chunk)


if __name__ == "__main__":
    bot.run(DISCORD_TOKEN)
