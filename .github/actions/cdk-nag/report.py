"""Report cdk-nag resilience findings from CDK's validation report (issue #94).

Usage: report.py --report cdk.out/validation-report.json --rules RULES
                 [--strict STRICT] [--min-reason 20] [--root DIR] [--comment OUT.md]

cdk-nag 3 runs as a CDK policy-validation plugin and writes its results into
the cloud assembly's validation-report.json. This keeps the NIST 800-53 rev 5
violations whose rule is in RULES (comma-separated names without the
"NIST.800.53.R5-" prefix, or a file of one name per line), annotates each at
the file and line in the app that created the construct, and fails when a
rule in STRICT is violated. An acknowledgement (Validations.of().acknowledge)
whose reason is shorter than --min-reason characters is reported, and for a
strict rule it does not count as acknowledged. Writes a Markdown summary to
--comment and prints violation-count, acknowledged-count, weak-count and
blocking-count for GITHUB_OUTPUT.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

PREFIX = "NIST.800.53.R5-"
FRAME = re.compile(r"\(?(/[^():\s]+):(\d+):\d+\)?")


def names(value):
    path = Path(value)
    text = path.read_text() if value and path.is_file() else value
    return {n.strip().removeprefix(PREFIX) for n in re.split(r"[,\n]", text)
            if n.strip() and not n.strip().startswith("#")}


def location(construct, root):
    # The first stack frame inside the app (not node_modules) is where the construct was created.
    for trace in construct.get("stackTraces", []):
        for match in FRAME.finditer(trace):
            path = Path(match.group(1))
            if "node_modules" in path.parts or "site-packages" in path.parts:
                continue
            try:
                return os.path.relpath(path.resolve(), Path.cwd()), match.group(2)
            except ValueError:
                return str(path), match.group(2)
    return root, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--rules", required=True)
    ap.add_argument("--strict", default="")
    ap.add_argument("--min-reason", type=int, default=20)
    ap.add_argument("--root", default=".")
    ap.add_argument("--comment", default="")
    args = ap.parse_args()

    rules, strict = names(args.rules), names(args.strict)
    unknown = strict - rules
    if unknown:
        print(f"::warning title=dr-check-cdk::strict-rules not in the reported rules, added: {', '.join(sorted(unknown))}",
              file=sys.stderr)
        rules |= unknown
    report = json.loads(Path(args.report).read_text())
    rows, counts = [], {"violation": 0, "acknowledged": 0, "weak": 0, "blocking": 0}
    for plugin in report.get("pluginReports", []):
        if not plugin.get("pluginName", "").startswith("NIST.800.53.R5"):
            continue
        for kind, entries in (("violation", plugin.get("violations", [])),
                              ("acknowledged", plugin.get("suppressedViolations", []))):
            for v in entries:
                rule = v.get("ruleName", "").removeprefix(PREFIX)
                if rule not in rules:
                    continue
                reason = (v.get("reason") or "").strip()
                weak = kind == "acknowledged" and len(reason) < args.min_reason
                for c in v.get("violatingConstructs", []):
                    path, line = location(c, args.root)
                    where = f"file={path}" + (f",line={line}" if line else "")
                    blocks = rule in strict and (kind == "violation" or weak)
                    counts[kind] += 1
                    counts["weak"] += weak
                    counts["blocking"] += blocks
                    construct = c.get("constructPath", "")
                    if kind == "violation":
                        level = "error" if blocks else "warning"
                        print(f"::{level} {where},title=cdk-nag {rule}::{construct}: {v.get('description', '')[:300]}",
                              file=sys.stderr)
                        status = "blocks" if blocks else "reported"
                    elif weak:
                        level = "error" if blocks else "warning"
                        print(f"::{level} {where},title=cdk-nag {rule} acknowledged without a real reason::{construct}: "
                              f"reason '{reason}' is under {args.min_reason} characters", file=sys.stderr)
                        status = "acknowledged, reason too short" + (" (blocks)" if blocks else "")
                    else:
                        status = f"acknowledged: {reason}"
                    rows.append(f"| `{rule}` | `{construct}` | {path}{':' + line if line else ''} | {status} |")

    totals = (f"{counts['violation']} violation(s), {counts['acknowledged']} acknowledged "
              f"({counts['weak']} with a reason under {args.min_reason} characters), {counts['blocking']} blocking.")
    lines = ["<!-- dr-check-cdk -->", "### DR check (cdk-nag, NIST 800-53 rev 5 resilience rules)", "", totals, ""]
    if strict:
        lines += [f"Strict rules: {', '.join(sorted(strict))}", ""]
    if rows:
        lines += ["| Rule | Construct | Defined at | Status |", "|---|---|---|---|", *rows]
    else:
        lines.append("No findings for the resilience rules.")
    text = "\n".join(lines) + "\n"
    if args.comment:
        Path(args.comment).write_text(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(text)
    for key in ("violation", "acknowledged", "weak", "blocking"):
        print(f"{key}-count={counts[key]}")
    return 1 if counts["blocking"] else 0


if __name__ == "__main__":
    sys.exit(main())
