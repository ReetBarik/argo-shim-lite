#!/usr/bin/env python3
"""Rank Claude model IDs from a gateway catalog and pick the best per family.

Reads newline-separated model IDs on stdin, prints shell-safe assignments:

    BEST_OPUS=<id>
    BEST_SONNET=<id>
    BEST_HAIKU=<id>

Empty value when a family is absent. Gateways name the same model many ways
(claude-opus-5, claude-opus-4-7-20251115, us.anthropic.claude-opus-5-v1:0,
claude-3-5-sonnet-..., argo:claudeopus45), so parsing is heuristic; run with
--self-test to check the battery. ASKSAGE_MODEL / ARGO_MODEL env overrides in
the launcher remain the escape hatch if a catalog defeats the parser.
"""
import re
import sys

FAMILIES = ("opus", "sonnet", "haiku")


def _split_two_digit(groups):
    # A single 2-digit group with no separator ("opus45") is almost always
    # major+minor ("4-5"): no Claude major version has reached double digits.
    if len(groups) == 1 and 10 <= groups[0] <= 99:
        return [groups[0] // 10, groups[0] % 10]
    return groups


def parse_version(model_id, family):
    s = model_id.lower()
    tokens = [t for t in re.split(r"[^a-z0-9]+", s) if t]
    if family in tokens:
        idx = tokens.index(family)

        def collect(seq):
            groups = []
            for tok in seq:
                if re.fullmatch(r"\d+", tok):
                    n = int(tok)
                    if n >= 20200000:  # date stamp
                        break
                    groups.append(n)
                    if len(groups) == 2:
                        break
                else:
                    break  # alpha token ("v1", "latest") ends the version run
            return groups

        groups = collect(tokens[idx + 1:])
        if not groups:
            groups = collect(reversed(tokens[:idx]))
            groups.reverse()
    else:
        # family embedded in a token, e.g. "claudeopus45"
        m = re.search(family + r"[-_.:]?(\d+)(?:[._-](\d+))?", s)
        if not m:
            return None
        groups = [int(m.group(1))]
        if m.group(2) is not None:
            groups.append(int(m.group(2)))
    groups = _split_two_digit(groups)
    if not groups:
        return None
    return tuple((groups + [0, 0])[:2])


def canonicalize(mid):
    # Some gateways (e.g. Argo) list display names like "Claude Opus 4.8".
    # They accept the canonical API id too, and Claude Code's capability
    # detection (thinking mode, effort tiers) keys off canonical-form names —
    # so rewrite display names to canonical form. Ids without whitespace
    # (already-canonical, bedrock-style, squashed) pass through verbatim.
    if re.search(r"\s", mid.strip()):
        return re.sub(r"[\s.]+", "-", mid.strip().lower())
    return mid


def best_per_family(ids):
    out = {}
    for family in FAMILIES:
        candidates = []
        for mid in ids:
            if family not in mid.lower():
                continue
            ver = parse_version(mid, family)
            if ver is None:
                continue
            has_date = bool(re.search(r"\d{8}", mid))
            # highest version; among equals prefer undated then shorter alias
            candidates.append((ver, not has_date, -len(mid), mid))
        if candidates:
            out[family] = canonicalize(max(candidates)[3])
    return out


TESTS = {
    # (catalog, expected opus, expected sonnet, expected haiku)
    "anthropic-style": (
        ["claude-opus-4-7", "claude-opus-5", "claude-sonnet-4-6",
         "claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-6"],
        "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"),
    "dated": (
        ["claude-opus-4-1-20250805", "claude-opus-4-7-20251115",
         "claude-3-5-sonnet-20241022", "claude-sonnet-4-5-20250929",
         "claude-3-5-haiku-20241022"],
        "claude-opus-4-7-20251115", "claude-sonnet-4-5-20250929",
        "claude-3-5-haiku-20241022"),
    "bedrock-style": (
        ["us.anthropic.claude-opus-5-v1:0", "us.anthropic.claude-opus-4-6-v1:0",
         "us.anthropic.claude-sonnet-4-6-v1:0", "anthropic.claude-3-haiku-20240307-v1:0"],
        "us.anthropic.claude-opus-5-v1:0", "us.anthropic.claude-sonnet-4-6-v1:0",
        "anthropic.claude-3-haiku-20240307-v1:0"),
    "old-vs-new-naming": (
        ["claude-3-7-sonnet-20250219", "claude-sonnet-4-5", "claude-3-opus-20240229"],
        "claude-3-opus-20240229", "claude-sonnet-4-5", None),
    "squashed": (
        ["argo:claudeopus45", "argo:claudeopus5", "argo:claudesonnet46"],
        "argo:claudeopus5", "argo:claudesonnet46", None),
    "dated-and-bare-alias-tie": (
        ["claude-opus-5-20260115", "claude-opus-5"],
        "claude-opus-5", None, None),
    "minor-beats-major-order": (
        ["claude-opus-5-1", "claude-opus-5"],
        "claude-opus-5-1", None, None),
    # Verbatim ANL Argo gateway catalog (Aug 2026): display-style ids that
    # must canonicalize, mixed with non-Claude entries that must be ignored.
    "argo-display-names": (
        ["Claude Opus 5", "Claude Opus 4.8", "Claude Opus 4.7", "Claude Opus 4.6",
         "Claude Opus 4.5", "Claude Opus 4.1", "Claude Haiku 4.5", "Claude Sonnet 5",
         "Claude Sonnet 4.6", "Claude Sonnet 4.5", "gpt-5", "gemini-2.5-pro"],
        "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"),
}


def self_test():
    failures = 0
    for name, (catalog, opus, sonnet, haiku) in TESTS.items():
        got = best_per_family(catalog)
        for family, want in (("opus", opus), ("sonnet", sonnet), ("haiku", haiku)):
            if got.get(family) != want and want is not None:
                print(f"FAIL {name}: {family} -> {got.get(family)!r}, want {want!r}")
                failures += 1
    print("self-test:", "FAILED" if failures else "OK")
    return 1 if failures else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    ids = [line.strip() for line in sys.stdin if line.strip()]
    best = best_per_family(ids)
    for family in FAMILIES:
        print(f"BEST_{family.upper()}={best.get(family, '')}")
