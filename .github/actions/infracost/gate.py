#!/usr/bin/env python3
"""Cost threshold gate over Infracost JSON output (issue #91).

Usage: gate.py --json diff.json [--max-monthly-increase USD] [--max-percent-increase PCT]
               [--usage-file PATH] [--snippet FILE]

Reads totalMonthlyCost, pastTotalMonthlyCost, diffTotalMonthlyCost and
summary.totalUsageBasedResources. Fails (exit 1) when the monthly delta is
positive and exceeds the USD cap, or exceeds the percent cap of the base
total (a zero base with any increase counts as exceeded). Both caps at zero
is comment-only. Decreases never fail. Warns when usage-based resources are
present and no usage file was given or the given one is missing. Writes a
markdown snippet for the PR comment and the step summary; outputs
monthly-diff, monthly-total, percent-change, threshold, gate.
Exit 2 on a missing or unreadable file. Standard library only; python3 -I.
"""

import argparse
import json
import os
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

TITLE = "infracost"


def money(d):
    sign = "-" if d < 0 else "+"
    return f"{sign}${abs(d):,.2f}"


def dec(v):
    try:
        return Decimal(str(v)) if v is not None else Decimal(0)
    except InvalidOperation:
        return Decimal(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--max-monthly-increase", type=Decimal, default=Decimal(0))
    ap.add_argument("--max-percent-increase", type=Decimal, default=Decimal(0))
    ap.add_argument("--usage-file", default="")
    ap.add_argument("--snippet", default="")
    args = ap.parse_args()
    path = Path(args.json)
    if not path.is_file():
        print(f"::error title={TITLE}::Infracost JSON {path} not found")
        return 2
    try:
        data = json.loads(path.read_text())
    except ValueError as exc:
        print(f"::error title={TITLE}::cannot parse {path}: {exc}")
        return 2

    total = dec(data.get("totalMonthlyCost"))
    past = dec(data.get("pastTotalMonthlyCost"))
    diff = dec(data.get("diffTotalMonthlyCost"))
    percent = (diff / past * 100) if past > 0 else None
    percent_text = f"{percent:+.1f}%" if percent is not None else "n/a"
    usage_based = int((data.get("summary") or {}).get("totalUsageBasedResources") or 0)

    checks, failures = [], []
    if args.max_monthly_increase > 0:
        exceeded = diff > args.max_monthly_increase
        checks.append(f"max monthly increase ${args.max_monthly_increase:,.2f} ({'exceeded' if exceeded else 'within'})")
        if exceeded:
            failures.append(f"monthly increase ${diff:,.2f} exceeds the ${args.max_monthly_increase:,.2f} cap")
    if args.max_percent_increase > 0:
        if diff <= 0:
            exceeded = False
        elif percent is None:
            exceeded = True
        else:
            exceeded = percent > args.max_percent_increase
        checks.append(f"max percent increase {args.max_percent_increase:g}% ({'exceeded' if exceeded else 'within'})")
        if exceeded:
            shown = f"{percent:.1f}%" if percent is not None else "an increase from a $0.00 base"
            failures.append(f"monthly increase of {shown} exceeds the {args.max_percent_increase:g}% cap")

    if not checks:
        gate, threshold = "comment-only", "none"
        head = "Cost gate: comment-only (no threshold set)"
    else:
        gate = "failed" if failures else "passed"
        threshold = ", ".join(checks)
        head = f"Cost gate: {gate}; threshold applied: {threshold}"
    line = f"{head}; monthly change {money(diff)} ({percent_text}), new total ${total:,.2f}/month."

    warnings = []
    if usage_based:
        if not args.usage_file:
            warnings.append(f"{usage_based} usage-based resources have no usage estimates; add an infracost-usage.yml "
                            "at the repo root (docs/cost-gate.md) or their cost shows as $0")
        elif not Path(args.usage_file).is_file():
            warnings.append(f"usage file {args.usage_file} not found; {usage_based} usage-based resources show as $0")
    for w in warnings:
        print(f"::warning title={TITLE}::{w}")
    for f in failures:
        print(f"::error title={TITLE}::{f}")

    snippet = [line] + [f"⚠️ {w}" for w in warnings]
    text = "\n\n".join(snippet) + "\n"
    print(text)
    if args.snippet:
        Path(args.snippet).write_text(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text + "\n")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"monthly-diff={diff:.2f}\nmonthly-total={total:.2f}\n"
                     f"percent-change={f'{percent:.1f}' if percent is not None else 'n/a'}\n"
                     f"threshold={threshold}\ngate={gate}\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
