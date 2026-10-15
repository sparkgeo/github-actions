#!/usr/bin/env python3
"""Summarise a garak report and compare hit rates with a threshold (#105).

Usage: gate.py --report FILE.report.jsonl --max-hit-rate 0.1 [--summary FILE]

Reads garak's "eval" entries (one per probe and detector): hit rate =
fails / total_evaluated. Writes a Markdown table (worst first) to --summary
and to stdout, and to GITHUB_OUTPUT: max-hit-rate, over-threshold
(true/false) and failing (probe/detector pairs above the threshold). Exit 0
unless the report has no eval entries (exit 1: the scan did not run).
Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--max-hit-rate", type=float, required=True)
    ap.add_argument("--summary", default="")
    a = ap.parse_args()

    rows = []
    with open(a.report, encoding="utf-8") as f:
        for line in f:
            e = json.loads(line)
            if e.get("entry_type") != "eval":
                continue
            total = int(e.get("total_evaluated") or 0)
            fails = int(e.get("fails") or 0)
            rate = fails / total if total else 0.0
            rows.append((rate, e.get("probe", ""), e.get("detector", ""), fails, total))
    if not rows:
        print("::error title=garak::no eval entries in the report; the scan did not complete")
        sys.exit(1)
    rows.sort(key=lambda r: (-r[0], r[1], r[2]))
    failing = [f"{p}/{d}" for rate, p, d, _, _ in rows if rate > a.max_hit_rate]
    table = [f"### garak: hit rate per probe (threshold {a.max_hit_rate:g})", "",
             "| Probe | Detector | Hits | Evaluated | Hit rate | |", "|---|---|---|---|---|---|"]
    for rate, p, d, fails, total in rows:
        table.append(f"| {p} | {d} | {fails} | {total} | {rate:.1%} | {'over' if rate > a.max_hit_rate else ''} |")
    text = "\n".join(table) + "\n"
    print(text)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(text)
    for p in failing:
        print(f"::warning title=garak::{p} hit rate above {a.max_hit_rate:g}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write(f"max-hit-rate={rows[0][0]:.4f}\nover-threshold={'true' if failing else 'false'}\n"
                    f"failing={','.join(failing)}\n")


if __name__ == "__main__":
    main()
