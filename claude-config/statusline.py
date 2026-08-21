#!/usr/bin/env python3
"""Status line: model | effort | context size (colored) | cost | +/- lines.

Reads Claude Code's statusline JSON on stdin (see docs/statusline). Context
color thresholds match the operating rules: green < 150K, yellow < 300K,
red >= 300K — red means "find a phase boundary and split".
"""
import json
import sys

GREEN, YELLOW, RED, DIM, RESET = "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"


def fmt_tokens(n):
    return f"{n/1000:.0f}K" if n < 1_000_000 else f"{n/1e6:.2f}M"


def main():
    d = json.load(sys.stdin)
    parts = []

    model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id", "?")
    effort = (d.get("effort") or {}).get("level")
    parts.append(f"{model}{' ' + effort if effort else ''}")

    cw = d.get("context_window") or {}
    usage = cw.get("current_usage") or {}
    ctx = sum(usage.get(k) or 0 for k in
              ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    if not ctx:
        ctx = cw.get("total_input_tokens") or 0
    if ctx:
        color = GREEN if ctx < 150_000 else YELLOW if ctx < 300_000 else RED
        pct = cw.get("used_percentage")
        pct_s = f" ({pct:.0f}%)" if isinstance(pct, (int, float)) else ""
        tail = " SPLIT?" if ctx >= 300_000 else ""
        parts.append(f"{color}ctx {fmt_tokens(ctx)}{pct_s}{tail}{RESET}")

    cost = (d.get("cost") or {})
    usd = cost.get("total_cost_usd")
    if isinstance(usd, (int, float)) and usd > 0:
        parts.append(f"${usd:.2f}")
    added, removed = cost.get("total_lines_added"), cost.get("total_lines_removed")
    if added or removed:
        parts.append(f"+{added or 0}/-{removed or 0}")

    print(f" {DIM}|{RESET} ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("statusline error")
