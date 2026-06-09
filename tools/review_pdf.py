#!/usr/bin/env python3
"""Chunked PDF peer review via Argo API (Claude Opus 4.7).

Usage: review_pdf.py <path-to-pdf>

Splits the PDF into CHUNK_PAGES-page chunks, sends each natively to
/v1/messages as a document content block (preserving equations and figures),
accumulates section summaries, then runs a synthesis call that produces
the structured peer review. Output is written to stdout for OpenClaw to relay.
"""

import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request

import pikepdf

ARGO_BASE = os.environ.get("ANTHROPIC_BASE_URL", "http://127.0.0.1:8084/argoapi").rstrip("/")
ARGO_KEY = os.environ.get("ANTHROPIC_API_KEY", "rbarik")
MODEL = "claudeopus47"
MAX_CHUNK_B64 = 700_000  # bytes; leaves headroom under Argo's 1MB body limit


def call_api(messages, max_tokens=1024):
    payload = {"model": MODEL, "max_tokens": max_tokens, "messages": messages}
    req = urllib.request.Request(
        f"{ARGO_BASE}/v1/messages",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {ARGO_KEY}",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read())
        return body["content"][0]["text"]
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Argo API error {e.code}: {e.read().decode()[:300]}") from e


def pages_b64(src, page_indices):
    out = pikepdf.Pdf.new()
    for i in page_indices:
        out.pages.append(src.pages[i])
    buf = io.BytesIO()
    out.save(buf)
    return base64.standard_b64encode(buf.getvalue()).decode()


def build_chunks(src):
    """Group pages into chunks whose base64 size stays under MAX_CHUNK_B64."""
    total = len(src.pages)
    chunks = []
    current = []

    for i in range(total):
        candidate = current + [i]
        b64 = pages_b64(src, candidate)
        if len(b64) > MAX_CHUNK_B64 and current:
            chunks.append(current)
            current = [i]
        else:
            current = candidate

    if current:
        chunks.append(current)
    return chunks


def main():
    if len(sys.argv) < 2:
        print("Usage: review_pdf.py <path>", file=sys.stderr)
        sys.exit(1)

    pdf_path = sys.argv[1]

    src = pikepdf.open(pdf_path)
    chunks = build_chunks(src)
    n = len(chunks)
    summaries = []

    for idx, page_indices in enumerate(chunks):
        b64 = pages_b64(src, page_indices)
        start, end = page_indices[0] + 1, page_indices[-1] + 1

        prior = (
            f"\n\nContext from earlier sections:\n{summaries[-1]}" if summaries else ""
        )
        prompt = (
            f"This is section {idx + 1} of {n} of a research paper "
            f"(pages {start}–{end}).{prior}\n\n"
            "Summarize the key contributions, methodology, results, and "
            "any important equations or algorithms in this section. Be concise."
        )

        summary = call_api(
            [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "document",
                            "source": {
                                "type": "base64",
                                "media_type": "application/pdf",
                                "data": b64,
                            },
                        },
                        {"type": "text", "text": prompt},
                    ],
                }
            ]
        )
        summaries.append(summary)

    src.close()

    combined = "\n\n---\n\n".join(
        f"**Section {i + 1} (pages {chunks[i][0] + 1}–{chunks[i][-1] + 1}):**\n{s}"
        for i, s in enumerate(summaries)
    )

    review_prompt = (
        f"You have read a complete research paper in {n} sections. "
        f"Section summaries:\n\n{combined}\n\n"
        "Write a peer review from an HPC/parallel computing perspective:\n\n"
        "**Core contribution** (1-2 sentences)\n"
        "**Methodology** (key technical approach)\n"
        "**HPC evaluation:**\n"
        "- Scalability: are scaling claims substantiated? Weak vs strong scaling?\n"
        "- Portability: CUDA-only vs Kokkos/SYCL/HIP?\n"
        "- Reproducibility: is the experimental setup precise enough to reproduce?\n"
        "- Rigor: are baselines fair? Is statistical variance reported?\n"
        "**Strengths** (bullet list)\n"
        "**Weaknesses** (bullet list)\n"
        "**Recommendation:** Strong Accept / Weak Accept / Weak Reject / Strong Reject "
        "+ 1-2 line justification\n\n"
        "Keep it Discord-scannable. Use bullet lists, not prose paragraphs."
    )

    review = call_api(
        [{"role": "user", "content": review_prompt}], max_tokens=2048
    )
    print(review)


if __name__ == "__main__":
    main()
