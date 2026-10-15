"""Gate GuardDog results against fail-on and a reviewed allowlist, write
SARIF and the job summary (issue #229).

Usage: gate.py --results DIR --sources sources.json --fail-on high|medium|none
               [--allowlist .guarddog-allowlist.yml] [--sarif out.sarif]

DIR holds <ecosystem>*.json files, each a list of {dependency, version,
result} as `guarddog <eco> verify --output-format json` writes them. A
package blocks when GuardDog's package label (risk_score.label) is at or above
fail-on, unless every rule behind its risks is allowlisted for that exact
name@version. Allowlisted findings stay in the SARIF as suppressed results.
Prints blocking-count, flagged-count, scanned-count and error-count for
GITHUB_OUTPUT; exits 1 when something blocks.
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path

import yaml

RANK = {"no_risks_detected": 0, "low": 1, "suspicious": 2, "high_risk": 3}
THRESHOLD = {"high": 3, "medium": 2, "none": 99}
LEVEL = {"high": "error", "medium": "warning", "low": "note"}
REQUIRED = ("package", "rule", "reviewer", "date")


def load_allowlist(path):
    if not path or not Path(path).is_file():
        return {}
    doc = yaml.safe_load(Path(path).read_text()) or {}
    allowed = {}
    for i, entry in enumerate(doc.get("exceptions") or []):
        missing = [k for k in REQUIRED if not isinstance(entry, dict) or not entry.get(k)]
        if missing:
            sys.exit(f"::error file={path},title=malicious-package-check::exception {i + 1} is missing {', '.join(missing)}")
        if not isinstance(entry["date"], datetime.date):
            try:
                datetime.date.fromisoformat(str(entry["date"]))
            except ValueError:
                sys.exit(f"::error file={path},title=malicious-package-check::exception {i + 1} date must be YYYY-MM-DD")
        allowed.setdefault(str(entry["package"]), {})[str(entry["rule"])] = entry
    return allowed


def line_of(path, name):
    try:
        for n, line in enumerate(Path(path).read_text(errors="replace").splitlines(), 1):
            if name in line:
                return n
    except OSError:
        pass
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--sources", required=True)
    ap.add_argument("--fail-on", default="high", choices=sorted(THRESHOLD))
    ap.add_argument("--allowlist", default="")
    ap.add_argument("--sarif", default="")
    args = ap.parse_args()

    sources = json.loads(Path(args.sources).read_text()) if Path(args.sources).is_file() else {}
    allowed = load_allowlist(args.allowlist)
    threshold = THRESHOLD[args.fail_on]
    rules, results, rows = {}, [], []
    counts = {"blocking": 0, "flagged": 0, "scanned": 0, "error": 0}

    for file in sorted(Path(args.results).glob("*.json")):
        eco = file.stem.split("-")[0]
        for dep in json.loads(file.read_text() or "[]"):
            name, version = dep.get("dependency", ""), dep.get("version", "")
            key = f"{name}@{version}" if version else name
            source = sources.get(f"{eco}:{key}", name if eco == "vsix" else "")
            result = dep.get("result") or {}
            counts["scanned"] += 1
            if result.get("errors") or "risk_score" not in result:
                counts["error"] += 1
                detail = "; ".join(f"{k}: {v}" for k, v in (result.get("errors") or {}).items()) or "no result"
                print(f"::warning title=malicious-package-check::GuardDog could not fully analyse {eco} {key}: {detail[:300]}", file=sys.stderr)
            label = (result.get("risk_score") or {}).get("label", "no_risks_detected")
            score = (result.get("risk_score") or {}).get("score", 0)
            risks = result.get("risks") or []
            if RANK.get(label, 0) == 0 and not risks:
                continue
            counts["flagged"] += 1
            exceptions = allowed.get(key, {})
            cleared = bool(risks) and all(r.get("threat_rule") in exceptions for r in risks)
            blocks = RANK.get(label, 0) >= threshold and not cleared
            counts["blocking"] += blocks
            status = "blocks" if blocks else ("allowlisted" if cleared else "reported")
            rows.append(f"| {eco} | `{key}` | {label} ({score}/10) | {', '.join(sorted({r.get('threat_rule', '') for r in risks}))} | `{source}` | {status} |")
            if blocks:
                print(f"::error file={source},line={line_of(source, name)},title=malicious-package-check::"
                      f"{eco} {key}: GuardDog {label} ({score}/10). Remove it, or have a reviewer add each rule for "
                      f"{key} to the allowlist", file=sys.stderr)
            for r in risks:
                rule = r.get("threat_rule") or "guarddog"
                rules[rule] = {"id": rule, "shortDescription": {"text": r.get("threat_description") or rule}}
                sarif = {
                    "ruleId": rule,
                    "level": LEVEL.get(r.get("severity"), "warning"),
                    "message": {"text": f"{eco} {key} (package risk {label}, {score}/10): "
                                        f"{r.get('threat_description', '')} at {r.get('file_path', '')} {r.get('threat_location', '')}".strip()},
                    "locations": [{"physicalLocation": {"artifactLocation": {"uri": source or "."},
                                                        "region": {"startLine": line_of(source, name)}}}],
                    "partialFingerprints": {"guarddog/v1": f"{eco}:{key}:{rule}:{r.get('threat_location', '')}"},
                }
                if rule in exceptions:
                    e = exceptions[rule]
                    sarif["suppressions"] = [{"kind": "external", "status": "accepted",
                                              "justification": f"reviewed by {e['reviewer']} on {e['date']}: {e.get('reason', '')}".strip(": ")}]
                results.append(sarif)

    if args.sarif:
        Path(args.sarif).write_text(json.dumps({
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json", "version": "2.1.0",
            "runs": [{"tool": {"driver": {"name": "GuardDog", "informationUri": "https://github.com/DataDog/guarddog",
                                          "rules": sorted(rules.values(), key=lambda x: x["id"])}},
                      "results": results}]}, indent=2))

    summary = [f"### Malicious package check (fail-on: {args.fail_on})", "",
               (f"{counts['scanned']} package(s) scanned, {counts['flagged']} flagged, {counts['blocking']} blocking, "
                f"{counts['error']} not fully analysed."), ""]
    if rows:
        summary += ["| Ecosystem | Package | GuardDog label | Rules | Source | Status |", "|---|---|---|---|---|---|", *rows]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(summary) + "\n")
    else:
        print("\n".join(summary), file=sys.stderr)
    for k, v in counts.items():
        print(f"{k}-count={v}")
    return 1 if counts["blocking"] else 0


if __name__ == "__main__":
    sys.exit(main())
