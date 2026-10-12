#!/usr/bin/env python3
"""Playwright JUnit XML to step summary and outputs (issue #75).

Usage: summary.py --junit results.xml [--shard i/n]

Outputs tests-total, tests-failed, tests-skipped; writes a per-file table
and the failed tests with their messages to GITHUB_STEP_SUMMARY. Emits no
annotations: the `github` reporter already places one per failure with file
and line. Exit 1 when any test failed, 2 when the file is missing.
Standard library only; run with python3 -I.
"""

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

TITLE = "playwright"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--junit", required=True)
    ap.add_argument("--shard", default="")
    args = ap.parse_args()
    path = Path(args.junit)
    if not path.is_file():
        print(f"::error title={TITLE}::JUnit file {path} not found (did playwright test run?)")
        return 2
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        print(f"::error title={TITLE}::cannot parse {path}: {exc}")
        return 2

    suites, failed_cases = [], []
    total = failed = skipped = 0
    for suite in root.iter("testsuite"):
        s_total = s_failed = s_skipped = 0
        for case in suite.iter("testcase"):
            s_total += 1
            if case.find("failure") is not None or case.find("error") is not None:
                s_failed += 1
                node = case.find("failure") if case.find("failure") is not None else case.find("error")
                message = (node.get("message") or (node.text or "").strip().splitlines()[0:1] or [""])
                message = message if isinstance(message, str) else message[0]
                detail = " ".join((node.text or "").split())[:300]
                failed_cases.append((suite.get("name", ""), case.get("name", ""), message, detail))
            elif case.find("skipped") is not None:
                s_skipped += 1
        suites.append((suite.get("name", ""), s_total, s_failed, s_skipped, suite.get("time", "")))
        total += s_total
        failed += s_failed
        skipped += s_skipped

    shard = f" (shard {args.shard})" if args.shard else ""
    lines = [f"## Playwright{shard}: {total} tests, {failed} failed, {skipped} skipped", "",
             "| File | Tests | Failed | Skipped | Time (s) |", "|---|---|---|---|---|"]
    lines += [f"| {n} | {t} | {f} | {s} | {tm} |" for n, t, f, s, tm in suites]
    if failed_cases:
        lines += ["", "### Failed", ""]
        for file, name, message, detail in failed_cases:
            lines.append(f"- **{file}** › {name}: {message}")
            if detail:
                lines.append(f"  `{detail}`")
    text = "\n".join(lines) + "\n"
    print(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write(text)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"tests-total={total}\ntests-failed={failed}\ntests-skipped={skipped}\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
