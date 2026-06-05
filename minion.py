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

import discord
import pdfplumber
from anthropic import AsyncAnthropic

from tools import github, literature, web

# ── Configuration ─────────────────────────────────────────────────────────────

DISCORD_TOKEN = os.environ["DISCORD_TOKEN"]
ARGO_USER     = os.environ.get("ARGO_USER", os.environ.get("USER", "minion"))
PROXY_URL     = os.environ.get("PROXY_URL", "http://127.0.0.1:8084/argoapi/")
MODEL         = os.environ.get("ARGO_MODEL", "claude-sonnet-4-5-20251001")

MAX_HISTORY     = 30
MAX_TOOL_ROUNDS = 10

# Channel IDs
_GENERAL     = 1509721938396971162
_OPENCLAW    = 1509722172787003603
_LIT_REVIEW  = 1511179825010835466
_CODE_DEV    = 1511179911459635251
_PEER_REVIEW = 1511180032838471681

CHANNEL_FOCUS: dict[int, str] = {
    _GENERAL:     "general assistant — answer questions, help with any task",
    _OPENCLAW:    "OpenClaw and Claude Code tooling — configuration, debugging, and usage",
    _LIT_REVIEW:  "literature search and paper analysis — use Semantic Scholar and arXiv, summarize findings, compare papers",
    _CODE_DEV:    "code and GitHub tasks — read and write files, create issues and PRs, review code",
    _PEER_REVIEW: "peer review of research papers — critically evaluate methodology, results, clarity, and novelty",
}

CHANNEL_TOOLS: dict[int, list] = {
    _GENERAL:     github.TOOLS + literature.TOOLS + web.TOOLS,
    _OPENCLAW:    github.TOOLS + web.TOOLS,
    _LIT_REVIEW:  literature.TOOLS + web.TOOLS,
    _CODE_DEV:    github.TOOLS + web.TOOLS,
    _PEER_REVIEW: literature.TOOLS + web.TOOLS,
}

ALL_HANDLERS = {**github.HANDLERS, **literature.HANDLERS, **web.HANDLERS}

# ── Clients ───────────────────────────────────────────────────────────────────

llm = AsyncAnthropic(base_url=PROXY_URL, api_key=ARGO_USER)

intents = discord.Intents.default()
intents.message_content = True
bot = discord.Client(intents=intents)

history: dict[int, list[dict]] = {}
loaded_paper: dict[int, dict] = {}  # channel_id -> {filename, text}

# ── Agent loop ────────────────────────────────────────────────────────────────

_PEER_REVIEW_PROMPT = """\
You are Minion, an AI research assistant working for Reet Barik, a researcher with deep expertise in:
- High Performance Computing (HPC)
- Parallel algorithms for combinatorial optimization
- Scaling AI pretraining and inference
- Portability frameworks: Kokkos, SYCL, OpenMP, HIP, CUDA

When a paper is loaded, approach it top-down: open with the high-level contribution and where it sits \
in the field, then drill into methodology, experiments, and implementation details as Reet asks follow-up questions.

When asked to write a review, use exactly this format:

**Summary**
[One paragraph: the paper's core contribution and context in the field]

**Strengths**
- ...

**Weaknesses**
- ...

**Recommendation:** [Strong Accept / Weak Accept / Weak Reject / Strong Reject]
[1–2 sentence justification]

Evaluate through the lens of Reet's expertise: flag weak scalability claims, questionable portability \
assumptions, missing baselines, reproducibility issues, and experimental rigor.

Guidelines:
- Be concise — Discord messages should be scannable, not walls of text
- Use code blocks for pseudocode or snippets, bullet points for lists
- For long answers, summarize and offer to go deeper on request\
"""


def _system_prompt(channel_id: int) -> str:
    if channel_id == _PEER_REVIEW:
        return _PEER_REVIEW_PROMPT
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


async def execute_tool(name: str, inputs: dict) -> str:
    try:
        handler = ALL_HANDLERS.get(name)
        if handler:
            return await handler(**inputs)
        return f"Unknown tool: {name}"
    except Exception as exc:
        return f"Tool error ({name}): {exc}"


def _extract_pdf_bytes(data: bytes, max_pages: int = 40) -> str:
    with pdfplumber.open(io.BytesIO(data)) as pdf:
        return "\n\n".join(p.extract_text() or "" for p in pdf.pages[:max_pages]).strip()


async def run_agent(channel_id: int, user_message: str) -> str:
    ch_history = history.setdefault(channel_id, [])
    ch_history.append({"role": "user", "content": user_message})

    if len(ch_history) > MAX_HISTORY:
        ch_history[:] = ch_history[-MAX_HISTORY:]

    # Prepend loaded paper as the opening exchange so the model always has full text in view
    paper = loaded_paper.get(channel_id)
    if paper:
        preamble = [
            {"role": "user", "content": f"Here is the paper to review ({paper['filename']}):\n\n{paper['text']}"},
            {"role": "assistant", "content": f"I've read **{paper['filename']}**. Ready to discuss — where would you like to start?"},
        ]
        messages = preamble + list(ch_history)
    else:
        messages = list(ch_history)

    tools = CHANNEL_TOOLS.get(channel_id, github.TOOLS + literature.TOOLS + web.TOOLS)

    for _ in range(MAX_TOOL_ROUNDS):
        response = await llm.messages.create(
            model=MODEL,
            max_tokens=4096,
            system=_system_prompt(channel_id),
            tools=tools,
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

CHANNEL_HELP: dict[int, str] = {
    _GENERAL: (
        "**Minion — general**\n"
        "Just talk to me. I can answer questions, help with tasks, search the web, and more.\n\n"
        "`!clear` — reset conversation history\n"
        "`!tunnel` — restart the Argo SSH tunnel (sends Duo push to your phone)"
    ),
    _OPENCLAW: (
        "**Minion — OpenClaw / Claude Code**\n"
        "Ask me anything about OpenClaw configuration, Claude Code usage, or debugging the Argo setup.\n\n"
        "`!clear` — reset conversation history\n"
        "`!tunnel` — restart the Argo SSH tunnel (sends Duo push to your phone)"
    ),
    _LIT_REVIEW: (
        "**Minion — literature review**\n"
        "- Search papers: just describe what you're looking for\n"
        "- Fetch a paper: paste an arXiv ID or URL\n"
        "- Fetch a PDF: paste a direct PDF URL\n\n"
        "`!clear` — reset conversation history\n"
        "`!tunnel` — restart the Argo SSH tunnel (sends Duo push to your phone)"
    ),
    _CODE_DEV: (
        "**Minion — code development**\n"
        "- `list the repos you have access to` — show available GitHub repos\n"
        "- Read/write files, create issues or PRs in any accessible repo\n"
        "- General coding help and code review\n\n"
        "`!clear` — reset conversation history\n"
        "`!tunnel` — restart the Argo SSH tunnel (sends Duo push to your phone)"
    ),
    _PEER_REVIEW: (
        "**Minion — peer review**\n"
        "- **Upload a PDF** — attach it to any message; Minion reads the full paper\n"
        "- **Ask questions** — explore the paper top-down; Minion answers from the HPC/parallel computing perspective\n"
        "- **`write my review`** — generates a structured review:\n"
        "  - Summary paragraph\n"
        "  - Strengths / Weaknesses\n"
        "  - Recommendation (Strong/Weak Accept/Reject)\n\n"
        "`!clear` — unload the current paper and reset conversation\n"
        "`!tunnel` — restart the Argo SSH tunnel (sends Duo push to your phone)"
    ),
}


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

    if message.content.strip() == "!tunnel":
        import socket
        try:
            with socket.create_connection(("127.0.0.1", 8085), timeout=2):
                await message.channel.send("Tunnel is already up on port 8085.")
        except (ConnectionRefusedError, OSError):
            await message.channel.send("Starting tunnel — approve the Duo push on your phone.")
            try:
                proc = await asyncio.create_subprocess_exec(
                    os.path.expanduser("~/argo-shim-lite/start-minion-tunnel.sh"),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=90)
                if proc.returncode == 0:
                    await message.channel.send("Tunnel is up.")
                else:
                    output = (stdout + stderr).decode().strip()
                    await message.channel.send(f"Tunnel failed: {output or 'unknown error'}")
            except asyncio.TimeoutError:
                await message.channel.send("Timed out waiting for Duo — try again.")
        return

    if message.content.strip() == "!help":
        help_text = CHANNEL_HELP.get(message.channel.id, "No help available for this channel.")
        await message.channel.send(help_text)
        return

    if message.content.strip() == "!clear":
        history.pop(message.channel.id, None)
        loaded_paper.pop(message.channel.id, None)
        await message.channel.send("Conversation history cleared.")
        return

    # PDF attachment in peer-review: extract, store, start fresh
    if message.channel.id == _PEER_REVIEW and message.attachments:
        pdf_attachment = next(
            (a for a in message.attachments if a.filename.lower().endswith(".pdf")), None
        )
        if pdf_attachment:
            async with message.channel.typing():
                try:
                    data = await pdf_attachment.read()
                    text = await asyncio.to_thread(_extract_pdf_bytes, data)
                    loaded_paper[message.channel.id] = {"filename": pdf_attachment.filename, "text": text}
                    history.pop(message.channel.id, None)
                    word_count = len(text.split())
                    await message.channel.send(
                        f"Loaded **{pdf_attachment.filename}** ({word_count:,} words extracted). "
                        "Ask me anything, or say 'write my review' when ready."
                    )
                except Exception as exc:
                    await message.channel.send(f"⚠️ Failed to read PDF: {exc}")
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
