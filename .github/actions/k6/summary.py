#!/usr/bin/env python3
"""Render a k6 --summary-export file into the job summary and step outputs
(issue #74).

Usage: summary.py --summary summary.json [--title NAME]

Outputs: thresholds-failed, thresholds-total, p95-ms, error-rate (percent),
requests, rps. Exit 1 when any threshold was crossed (k6 itself exits 99 in
that case; this keeps the gate when the summary is rendered separately), 2
when the file is missing or unreadable. Standard library only; python3 -I.
"""

import argparse
import json
import os
import sys
from pathlib import Path

TITLE = "k6"


def usage_error(msg):
    print(f"::error title={TITLE}::{msg}")
    return 2


def fmt(v, digits=1):
    return "" if v is None else f"{v:.{digits}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", required=True)
    ap.add_argument("--title", default="k6")
    args = ap.parse_args()
    path = Path(args.summary)
    if not path.is_file():
        return usage_error(f"summary file {path} not found")
    try:
        data = json.loads(path.read_text())
        metrics = data["metrics"]
    except (ValueError, KeyError, TypeError) as exc:
        return usage_error(f"cannot read {path}: {exc}")

    dur = metrics.get("http_req_duration", {})
    failed = metrics.get("http_req_failed", {})
    reqs = metrics.get("http_reqs", {})
    checks = metrics.get("checks", {})
    vus = metrics.get("vus_max", {})
    p95 = dur.get("p(95)")
    error_rate = (failed.get("value") or 0) * 100
    requests = int(reqs.get("count") or 0)
    rps = reqs.get("rate")

    # thresholds: {"expr": crossed?} per metric in the legacy export format.
    rows, crossed = [], 0
    for name, m in sorted(metrics.items()):
        for expr, failed_flag in sorted((m.get("thresholds") or {}).items()):
            rows.append((name, expr, bool(failed_flag)))
            if failed_flag:
                crossed += 1
                print(f"::error title={TITLE}::threshold {name} {expr} crossed")

    lines = [f"## Load test: {args.title}", "", "| Metric | Value |", "|---|---|",
             f"| Requests | {requests} |",
             f"| Requests per second | {fmt(rps)} |",
             f"| p95 latency | {fmt(p95)} ms |",
             f"| p99 latency | {fmt(dur.get('p(99)'))} ms |" if dur.get("p(99)") is not None else f"| Median latency | {fmt(dur.get('med'))} ms |",
             f"| Max latency | {fmt(dur.get('max'))} ms |",
             f"| Error rate | {fmt(error_rate)} % |",
             f"| Checks passed | {int(checks.get('passes') or 0)} / {int(checks.get('passes') or 0) + int(checks.get('fails') or 0)} |",
             f"| Max VUs | {int(vus.get('max') or vus.get('value') or 0)} |",
             "", f"### Thresholds ({len(rows) - crossed} of {len(rows)} passed)", "",
             "| Metric | Threshold | Result |", "|---|---|---|"]
    lines += [f"| {n} | {e} | {'**fail**' if f else 'pass'} |" for n, e, f in rows]
    text = "\n".join(lines) + "\n"
    print(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write(text)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"thresholds-failed={crossed}\nthresholds-total={len(rows)}\np95-ms={fmt(p95)}\n"
                    f"error-rate={fmt(error_rate)}\nrequests={requests}\nrps={fmt(rps)}\n")
    return 1 if crossed else 0


if __name__ == "__main__":
    sys.exit(main())
