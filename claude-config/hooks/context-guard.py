#!/usr/bin/env python3
"""UserPromptSubmit hook: cold-cache tripwire + context-size advisory.

Two behaviors, both derived from a measured cost retrospective:

1. COLD-CACHE TRIPWIRE (blocks, once per idle gap): the prompt cache expires
   ~5 minutes after the last API activity. Submitting into a large idle
   context re-writes the entire prefix at the cache-write rate instead of
   the ~12x cheaper cached-read rate. When the session has been idle past
   the TTL with a large context, the first submission is blocked (exit 2)
   with the estimated cost; resending the same prompt proceeds (a marker
   file remembers the gap already warned about).

2. SIZE ADVISORY (never blocks): above a context threshold, a short note is
   added to Claude's context (exit 0 stdout) nudging it to follow the
   operating rules — offer a handoff prompt / suggest a session split at
   the next phase boundary.

Any error exits 0: this hook must never break prompting.
"""
import json
import os
import sys
from datetime import datetime, timezone

CACHE_TTL_SECONDS = 300
COLD_CTX_THRESHOLD = 150_000   # tokens: below this a rewrite is cheap enough
ADVISORY_CTX_THRESHOLD = 300_000
CACHE_WRITE_PER_MTOK = 12.5    # $ API-equivalent, order-of-magnitude only
TAIL_BYTES = 262_144


def read_tail_lines(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - TAIL_BYTES))
        data = f.read()
    lines = data.decode("utf-8", errors="replace").splitlines()
    return lines[1:] if size > TAIL_BYTES else lines  # drop partial first line


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def main():
    payload = json.load(sys.stdin)
    transcript = payload.get("transcript_path", "")
    session_id = payload.get("session_id", "unknown")
    if not transcript or not os.path.isfile(transcript):
        return 0

    last_activity_ts = None
    last_ctx = 0
    for line in read_tail_lines(transcript):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        ts = rec.get("timestamp")
        if ts:
            last_activity_ts = ts
        usage = (rec.get("message") or {}).get("usage") if rec.get("type") == "assistant" else None
        if usage:
            last_ctx = ((usage.get("input_tokens") or 0)
                        + (usage.get("cache_read_input_tokens") or 0)
                        + (usage.get("cache_creation_input_tokens") or 0))
    if last_activity_ts is None:
        return 0

    gap = (datetime.now(timezone.utc) - parse_ts(last_activity_ts)).total_seconds()

    if gap > CACHE_TTL_SECONDS and last_ctx >= COLD_CTX_THRESHOLD:
        marker_dir = os.path.expanduser("~/.claude/.context-guard")
        os.makedirs(marker_dir, exist_ok=True)
        marker = os.path.join(marker_dir, session_id)
        already_warned = False
        try:
            with open(marker) as f:
                already_warned = f.read().strip() == last_activity_ts
        except OSError:
            pass
        if not already_warned:
            with open(marker, "w") as f:
                f.write(last_activity_ts)
            cost = last_ctx * CACHE_WRITE_PER_MTOK / 1e6
            print(
                f"[context-guard] Session idle {gap/60:.0f} min with ~{last_ctx/1000:.0f}K-token "
                f"context: the prompt cache has expired, so this message re-writes the full prefix "
                f"(~${cost:.2f} API-equivalent). Consider /clear or a fresh session with a handoff "
                f"prompt. Resend the same message to proceed anyway.",
                file=sys.stderr,
            )
            return 2

    if last_ctx >= ADVISORY_CTX_THRESHOLD:
        print(
            f"[context-guard] Context is ~{last_ctx/1000:.0f}K tokens. Per the operating rules, "
            f"look for the next natural phase boundary and offer the user a handoff prompt for a "
            f"fresh session."
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
