"""Gate nuclei JSON export results on severity (issue #66).

Usage: gate.py --results nuclei.json --fail-on info|low|medium|high|critical|none

One annotation per finding: an error when it is at or above fail-on, a
warning otherwise. Prints critical-count, high-count, medium-count,
low-count, info-count and blocking-count for GITHUB_OUTPUT; exits 1 when a
finding blocks. A missing or empty export means no findings.
"""

import argparse
import json
import os
import sys
from pathlib import Path

RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--fail-on", default="high", choices=[*RANK, "none"])
    args = ap.parse_args()

    path = Path(args.results)
    text = path.read_text().strip() if path.is_file() else ""
    findings = json.loads(text) if text else []
    threshold = RANK.get(args.fail_on, 99)
    counts = dict.fromkeys(RANK, 0)
    blocking = 0
    rows = []
    for f in findings:
        info = f.get("info", {})
        sev = str(info.get("severity", "info")).lower()
        rank = RANK.get(sev, 0)
        counts[sev if sev in counts else "info"] += 1
        blocks = rank >= threshold
        blocking += blocks
        name = info.get("name", f.get("template-id", ""))
        where = f.get("matched-at") or f.get("host", "")
        level = "error" if blocks else "warning"
        print(f"::{level} title=nuclei {sev} {f.get('template-id', '')}::{name} at {where}", file=sys.stderr)
        rows.append((-rank, f"| {sev} | `{f.get('template-id', '')}` | {name} | {where} | {'blocks' if blocks else 'reported'} |"))

    summary = [f"### Nuclei (fail-on: {args.fail_on})", "",
               ", ".join(f"{k} {v}" for k, v in counts.items()) + f"; {blocking} blocking.", ""]
    if rows:
        summary += ["| Severity | Template | Finding | Matched at | Status |", "|---|---|---|---|---|",
                    *(line for _, line in sorted(rows))]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(summary) + "\n")
    for key, value in counts.items():
        print(f"{key}-count={value}")
    print(f"blocking-count={blocking}")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
