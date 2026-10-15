"""Gate a ZAP baseline JSON report (issue #65).

Usage: gate.py --report zap.json --fail-on high|medium|low|none [--rules rules.tsv]

Annotates each alert and fails when one is at or above fail-on. The rules
file is ZAP's own baseline config (`<plugin id>\\t<IGNORE|INFO|WARN|FAIL>\\t(name)`),
and it overrides the risk threshold per rule:
- IGNORE drops the alert;
- INFO and WARN report it without blocking;
- FAIL blocks whatever its risk.
Prints high-count, medium-count, low-count, info-count and blocking-count
for GITHUB_OUTPUT; exits 1 when something blocks.
"""

import argparse
import json
import os
import sys
from pathlib import Path

RISK = {3: "High", 2: "Medium", 1: "Low", 0: "Informational"}
THRESHOLD = {"high": 3, "medium": 2, "low": 1, "none": 99}


def load_rules(path):
    rules = {}
    if not path:
        return rules
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        parts = line.split("\t")
        if not line.strip() or line.lstrip().startswith("#") or len(parts) < 2:
            continue
        if parts[1] not in {"IGNORE", "INFO", "WARN", "FAIL"}:
            sys.exit(f"::error file={path},line={n},title=zap-baseline::rule level must be IGNORE, INFO, WARN or FAIL, got '{parts[1]}'")
        rules[parts[0].strip()] = parts[1]
    return rules


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--fail-on", default="high", choices=sorted(THRESHOLD))
    ap.add_argument("--rules", default="")
    ap.add_argument("--title", default="ZAP baseline")
    args = ap.parse_args()

    rules = load_rules(args.rules)
    threshold = THRESHOLD[args.fail_on]
    counts = {"high": 0, "medium": 0, "low": 0, "info": 0, "blocking": 0}
    rows = []
    for site in json.loads(Path(args.report).read_text()).get("site", []):
        for alert in site.get("alerts", []):
            plugin = str(alert.get("pluginid", ""))
            rule = rules.get(plugin)
            if rule == "IGNORE":
                continue
            risk = int(alert.get("riskcode", 0))
            counts[{3: "high", 2: "medium", 1: "low"}.get(risk, "info")] += 1
            blocks = rule == "FAIL" or (rule not in {"INFO", "WARN"} and risk >= threshold)
            counts["blocking"] += blocks
            uris = [i.get("uri", "") for i in alert.get("instances", [])]
            name = alert.get("name") or alert.get("alert", plugin)
            msg = (f"{name} ({RISK.get(risk, risk)}, plugin {plugin}) on {len(uris)} URL(s), "
                   f"e.g. {uris[0] if uris else site.get('@name', '')}")
            if blocks:
                print(f"::error title={args.title}::{msg}", file=sys.stderr)
            elif risk >= 1:
                print(f"::warning title={args.title}::{msg}", file=sys.stderr)
            status = "blocks" if blocks else (rule or "reported")
            rows.append((-risk, f"| {RISK.get(risk, risk)} | {name} | {plugin} | {len(uris)} | {status} |"))

    totals = (f"High {counts['high']}, Medium {counts['medium']}, Low {counts['low']}, "
              f"Informational {counts['info']}; {counts['blocking']} blocking.")
    summary = [f"### {args.title} (fail-on: {args.fail_on})", "", totals, ""]
    if rows:
        summary += ["| Risk | Alert | Plugin | URLs | Status |", "|---|---|---|---|---|",
                    *(line for _, line in sorted(rows))]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(summary) + "\n")
    for key, value in counts.items():
        print(f"{key}-count={value}")
    return 1 if counts["blocking"] else 0


if __name__ == "__main__":
    sys.exit(main())
