import io
import re

import httpx
import pdfplumber
from bs4 import BeautifulSoup

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
]


async def _search_literature(query: str, limit: int = 5) -> str:
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


async def _fetch_arxiv_paper(paper_id: str) -> str:
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


async def _fetch_pdf(url: str, max_pages: int = 10) -> str:
    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(url, timeout=30)
    with pdfplumber.open(io.BytesIO(resp.content)) as pdf:
        text = "\n\n".join(p.extract_text() or "" for p in pdf.pages[:max_pages])
    return text[:8000] if text.strip() else "Could not extract text from PDF."


HANDLERS = {
    "search_literature": _search_literature,
    "fetch_arxiv_paper": _fetch_arxiv_paper,
    "fetch_pdf": _fetch_pdf,
}
