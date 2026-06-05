import httpx
from bs4 import BeautifulSoup

TOOLS = [
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
]


async def _fetch_url(url: str) -> str:
    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(url, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["script", "style", "nav", "footer", "header"]):
        tag.decompose()
    return soup.get_text(separator="\n", strip=True)[:6000]


HANDLERS = {
    "fetch_url": _fetch_url,
}
