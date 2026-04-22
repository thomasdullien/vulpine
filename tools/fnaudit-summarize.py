#!/usr/bin/env python3
"""
fnaudit-summarize.py — produce a per-feature audit briefing (≤~800 tokens)
that stage 7 reads once per feature instead of walking every row in
audit-log.db in-context.

Joins three inputs:
  1. audit-log.db                                 (stage 6 output)
  2. features/<F>/functions.txt                   (symbol list for this feature)
  3. features/<F>/reachability.json               (dynamic classification)

Reachability evidence classes (strongest → weakest):
  dynamic-observed         — symbol fired in the stage-5 trace.ftrc
  static-only-reachable    — codenav says reachable from feature entry, not in trace
  no-path-found            — codenav returned unreachable (noise from coverage diff)
  unknown                  — not classified (ground truth missing; treat as weak)

Output: markdown. No hedging prose, no examples — dense data for stage 7.

Usage:
  fnaudit-summarize.py --feature F3-http2-priority --run $VULPINE_RUN
                       [--out features/F3-.../audit-summary.md]
                       [--top-n 10]
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

SEVERITY_RANK = {"critical": 4, "high": 3, "medium": 2, "low": 1, "info": 0}
REACH_RANK = {
    "dynamic-observed":      3,
    "static-only-reachable": 2,
    "unknown":               1,
    "no-path-found":         0,
}

# Heuristic categories used for "aggregate patterns". Keep this small; the
# stage-7 reader wants signal, not an exhaustive taxonomy.
AGGREGATE_KEYWORDS = {
    "attacker-length allocations": [
        r"int(eger)?[-_ ]overflow[-_ ]to[-_ ]alloc",
        r"unchecked[-_ ]length",
        r"attacker[-_ ]controlled[-_ ]size",
        r"malloc.*\* *n\b",
    ],
    "pointer-lifetime races":      [r"use[-_ ]after[-_ ]free", r"double[-_ ]free",
                                    r"TOCTOU", r"race", r"refcount"],
    "state-machine crossings":     [r"pre[-_ ]auth", r"authentication[-_ ]bypass",
                                    r"trust[-_ ]boundary", r"privilege"],
    "parser / deserialisation":    [r"ASN\.?1", r"BER", r"XDR", r"protobuf",
                                    r"parse", r"decod"],
    "integer / sign handling":     [r"signedness", r"sign[-_ ]extension",
                                    r"right[-_ ]shift", r"promotion"],
}


def load_reachability(run: Path, feature: str) -> dict[str, str]:
    """Return {symbol: reachability-class}. Missing file → everyone unknown."""
    path = run / "features" / feature / "reachability.json"
    if not path.is_file():
        return {}
    data = json.loads(path.read_text())
    out: dict[str, str] = {}
    for sym in data.get("observed", []):              out[sym] = "dynamic-observed"
    for sym in data.get("unobserved_reachable", []):  out[sym] = "static-only-reachable"
    for sym in data.get("unreachable_skipped", []):   out[sym] = "no-path-found"
    return out


def load_feature_symbols(run: Path, feature: str) -> set[str]:
    path = run / "features" / feature / "functions.txt"
    if not path.is_file():
        sys.exit(f"missing {path}")
    return {line.strip() for line in path.read_text().splitlines() if line.strip()}


def load_audits(db: Path, symbols: set[str]) -> list[dict]:
    """Return audit rows joined with the feature's symbol set."""
    if not db.is_file():
        sys.exit(f"missing audit-log.db at {db}")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = []
    # Use a temp table for the symbol set rather than IN (?…?) — symbols can be 500+.
    con.execute("CREATE TEMP TABLE sym(s TEXT PRIMARY KEY)")
    con.executemany("INSERT OR IGNORE INTO sym(s) VALUES (?)", [(s,) for s in symbols])
    for r in con.execute(
        """
        SELECT a.symbol_qualified, a.file_path, a.line_start, a.intent,
               a.issues, a.verification_status, a.verification_blocked_by,
               a.testability_notes, a.source_commit
          FROM audits a
          JOIN sym ON sym.s = a.symbol_qualified
        """
    ):
        rows.append(dict(r))
    con.close()
    return rows


def max_severity(issues_json: str | None) -> str:
    if not issues_json:
        return "info"
    try:
        issues = json.loads(issues_json)
    except json.JSONDecodeError:
        return "info"
    best = "info"
    for i in issues:
        sev = (i.get("severity") or "info").lower()
        if SEVERITY_RANK.get(sev, -1) > SEVERITY_RANK.get(best, -1):
            best = sev
    return best


def all_categories(issues_json: str | None) -> list[str]:
    try:
        return [(i.get("category") or "uncategorised").lower()
                for i in json.loads(issues_json or "[]")]
    except json.JSONDecodeError:
        return []


def first_description(issues_json: str | None) -> str:
    try:
        for i in json.loads(issues_json or "[]"):
            d = (i.get("description") or "").strip()
            if d:
                return d.splitlines()[0][:140]
    except json.JSONDecodeError:
        pass
    return ""


def detect_aggregates(rows: list[dict]) -> dict[str, int]:
    """Count how many audit rows match each aggregate-pattern keyword group."""
    buckets: dict[str, int] = defaultdict(int)
    for r in rows:
        text = " ".join(filter(None, [
            r.get("intent") or "",
            r.get("issues") or "",
            r.get("testability_notes") or "",
            r.get("verification_blocked_by") or "",
        ])).lower()
        for name, patterns in AGGREGATE_KEYWORDS.items():
            if any(re.search(p, text, re.I) for p in patterns):
                buckets[name] += 1
    return dict(buckets)


def render(feature: str, rows: list[dict], reach: dict[str, str], top_n: int) -> str:
    # Tag each row with severity + reachability class.
    annotated = []
    for r in rows:
        sym = r["symbol_qualified"]
        sev = max_severity(r.get("issues"))
        rc = reach.get(sym, "unknown")
        annotated.append({
            "sym": sym,
            "file": f"{r.get('file_path')}:{r.get('line_start')}",
            "sev": sev,
            "reach": rc,
            "cats": all_categories(r.get("issues")),
            "desc": first_description(r.get("issues")),
            "vs":   r.get("verification_status") or "THEORETICAL",
            "vb":   r.get("verification_blocked_by") or "",
        })
    annotated.sort(
        key=lambda x: (SEVERITY_RANK.get(x["sev"], -1), REACH_RANK.get(x["reach"], -1)),
        reverse=True,
    )

    reach_counts = Counter(x["reach"] for x in annotated)
    sev_counts   = Counter(x["sev"]   for x in annotated)
    cat_counts   = Counter(c for x in annotated for c in x["cats"])
    aggregates   = detect_aggregates(rows)

    static_only_high = [x for x in annotated
                        if x["reach"] == "static-only-reachable"
                        and SEVERITY_RANK.get(x["sev"], -1) >= SEVERITY_RANK["high"]]

    lines: list[str] = []
    w = lines.append

    w(f"# Audit summary — feature {feature}")
    w("")
    w(f"Audited symbols: **{len(annotated)}**. "
      f"Reachability evidence: "
      f"**{reach_counts.get('dynamic-observed', 0)}** observed in trace, "
      f"**{reach_counts.get('static-only-reachable', 0)}** static-only, "
      f"**{reach_counts.get('no-path-found', 0)}** no-path, "
      f"**{reach_counts.get('unknown', 0)}** unclassified.")
    w("")
    w(f"Severity mix: "
      + ", ".join(f"{sev_counts.get(s, 0)} {s}"
                  for s in ("critical", "high", "medium", "low", "info")))
    w("")

    w(f"## Top {min(top_n, len(annotated))} leads (severity × reachability)")
    w("")
    w("| # | Symbol | Sev | Reach | Categories | Lead |")
    w("|---|--------|-----|-------|------------|------|")
    for i, x in enumerate(annotated[:top_n], 1):
        cats = ", ".join(sorted(set(x["cats"]))[:3]) or "—"
        w(f"| {i} | `{x['sym']}` "
          f"({x['file']}) | {x['sev']} | {x['reach']} | {cats} | {x['desc']} |")
    w("")

    w("## Category distribution")
    w("")
    for cat, n in cat_counts.most_common(15):
        w(f"- {cat}: {n}")
    w("")

    if aggregates:
        w("## Aggregate patterns worth chaining")
        w("")
        for name, n in sorted(aggregates.items(), key=lambda kv: -kv[1]):
            if n == 0:
                continue
            w(f"- **{name}**: {n} audited symbols touch this pattern.")
        w("")

    if static_only_high:
        w("## Dynamic blind-spots (stage 7 needs a richer trigger)")
        w("")
        w(f"{len(static_only_high)} high/critical symbols are static-only-reachable "
          f"(codenav claims reachable, but the stage-5 fuzzer did not exercise "
          f"them). Cap severity at medium per spec unless stage 7 crafts a "
          f"trigger that actually hits them:")
        w("")
        for x in static_only_high[:20]:
            w(f"- `{x['sym']}` — {x['desc']}")
        w("")

    w("## Querying more detail")
    w("")
    w("Per-symbol: `fnaudit get <symbol>` (JSON). "
      "Recomputation: re-run this script. "
      "Reachability source: `features/" + feature + "/reachability.json`. "
      "Underlying DB: `$VULPINE_RUN/audit-log.db`.")
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--feature", required=True, help="feature slug under features/")
    ap.add_argument("--run", default=os.environ.get("VULPINE_RUN"),
                    help="VULPINE_RUN directory (defaults to env)")
    ap.add_argument("--out", help="write to file; default stdout")
    ap.add_argument("--top-n", type=int, default=10)
    args = ap.parse_args()
    if not args.run:
        sys.exit("set --run or VULPINE_RUN")
    run = Path(args.run)
    symbols = load_feature_symbols(run, args.feature)
    reach   = load_reachability(run, args.feature)
    rows    = load_audits(run / "audit-log.db", symbols)
    if not rows:
        sys.exit(f"no audit rows matched functions.txt for {args.feature}")
    md = render(args.feature, rows, reach, args.top_n)
    if args.out:
        Path(args.out).write_text(md)
        print(f"wrote {args.out} ({len(md)} bytes, {len(rows)} rows)")
    else:
        sys.stdout.write(md)


if __name__ == "__main__":
    main()
