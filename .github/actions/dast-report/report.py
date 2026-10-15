"""Combine scheduled DAST results and gate them (issue #68).

Usage: report.py --out findings.json --fail-on critical|high|medium|low|none
                 [--zap zap.json ...] [--nuclei nuclei.json]

Reads ZAP JSON reports (full scan and API scan) and a nuclei JSON export,
maps both onto one severity scale (ZAP High = high; nuclei keeps its own),
writes every High and Critical finding to --out for the tracking issue, and
fails when a finding is at or above fail-on. A missing file is skipped (its
scan job failed or did not run); the summary says so. Prints high-count,
critical-count and blocking-count for GITHUB_OUTPUT.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

RANK = {"info": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
ZAP_RISK = {"3": "high", "2": "medium", "1": "low", "0": "info"}


def load(path):
    p = Path(path)
    if not p.is_file() or not p.read_text().strip():
        return None
    return json.loads(p.read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--fail-on", default="high", choices=[*RANK, "none"])
    ap.add_argument("--zap", action="append", default=[])
    ap.add_argument("--nuclei", default="")
    args = ap.parse_args()

    findings, missing = [], []
    for path in args.zap:
        doc = load(path)
        if doc is None:
            missing.append(path)
            continue
        for site in doc.get("site", []):
            for alert in site.get("alerts", []):
                uri = (alert.get("instances") or [{}])[0].get("uri", site.get("@name", ""))
                findings.append({"tool": "zap", "id": str(alert.get("pluginid", "")),
                                 "severity": ZAP_RISK.get(str(alert.get("riskcode", "0")), "info"),
                                 "name": alert.get("name", ""), "where": uri,
                                 "key": f"zap:{alert.get('pluginid')}:{urlparse(uri).path}"})
    if args.nuclei:
        doc = load(args.nuclei)
        if doc is None:
            missing.append(args.nuclei)
        for f in doc or []:
            where = f.get("matched-at") or f.get("host", "")
            findings.append({"tool": "nuclei", "id": f.get("template-id", ""),
                             "severity": str(f.get("info", {}).get("severity", "info")).lower(),
                             "name": f.get("info", {}).get("name", ""), "where": where,
                             "key": f"nuclei:{f.get('template-id')}:{urlparse(where).path}"})

    threshold = RANK.get(args.fail_on, 99)
    serious = sorted((f for f in findings if RANK.get(f["severity"], 0) >= RANK["high"]),
                     key=lambda f: (-RANK[f["severity"]], f["key"]))
    blocking = [f for f in findings if RANK.get(f["severity"], 0) >= threshold]
    Path(args.out).write_text(json.dumps(serious, indent=2))
    for f in blocking:
        print(f"::error title=DAST scheduled ({f['tool']})::{f['severity']}: {f['name']} at {f['where']}", file=sys.stderr)

    counts = {s: sum(f["severity"] == s for f in findings) for s in ("critical", "high", "medium", "low")}
    lines = [f"### Scheduled DAST (fail-on: {args.fail_on})", "",
             ", ".join(f"{k} {v}" for k, v in counts.items()) + f"; {len(blocking)} blocking.", ""]
    if missing:
        lines += [f"Not available (scan failed or skipped): {', '.join(missing)}", ""]
    if serious:
        lines += ["| Severity | Tool | Finding | Where |", "|---|---|---|---|",
                  *(f"| {f['severity']} | {f['tool']} | {f['name']} | {f['where']} |" for f in serious)]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(lines) + "\n")
    print(f"high-count={counts['high']}")
    print(f"critical-count={counts['critical']}")
    print(f"blocking-count={len(blocking)}")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
