#!/usr/bin/env python3
"""Parse `crosshair check --report_all` output into SARIF and JSON
(verify-brief.yml step "CrossHair", issue #125).

Usage: crosshair.py --text crosshair.txt --sarif crosshair.sarif --json crosshair.json

CrossHair prints one line per contract: "<file>:<line>: <kind>: <message>".
Observed with crosshair-tool 0.0.111:
  error: false when calling f(1) (which returns 1)   <- counterexample, exit 1
  info: Confirmed over all paths.                    <- exhausted: every path explored
  info: Not confirmed.                               <- budget ran out or opaque call
SARIF rules: crosshair.counterexample (error), crosshair.not-verified (note).
"""

import argparse
import json
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--sarif", required=True)
    ap.add_argument("--json", required=True)
    args = ap.parse_args()
    pat = re.compile(r"^(?P<file>[^:\n]+?):(?P<line>\d+): (?P<kind>[^:]+): (?P<msg>.*)$")
    cex, unverified, other = [], [], []
    with open(args.text, encoding="utf-8", errors="ignore") as fh:
        for l in fh:
            m = pat.match(l.rstrip())
            if not m:
                continue
            d = m.groupdict()
            d["line"] = int(d["line"])
            k, msg = d["kind"].lower(), d["msg"].lower()
            if k == "error":
                cex.append(d)
            elif "confirmed over all paths" in msg:
                other.append(d)
            else:
                unverified.append(d)
    res = [{"ruleId": "crosshair.counterexample", "level": "error",
            "message": {"text": d["msg"][:400]},
            "locations": [{"physicalLocation": {"artifactLocation": {"uri": d["file"]},
                                                "region": {"startLine": d["line"]}}}]} for d in cex]
    res += [{"ruleId": "crosshair.not-verified", "level": "note",
             "message": {"text": d["msg"][:400]},
             "locations": [{"physicalLocation": {"artifactLocation": {"uri": d["file"]},
                                                 "region": {"startLine": d["line"]}}}]} for d in unverified]
    with open(args.sarif, "w") as fh:
        json.dump({"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "crosshair",
                   "rules": [{"id": "crosshair.counterexample", "defaultConfiguration": {"level": "error"}},
                             {"id": "crosshair.not-verified", "defaultConfiguration": {"level": "note"}}]}},
                   "results": res}]}, fh)
    with open(args.json, "w") as fh:
        json.dump({"counterexamples": cex, "unverified": unverified, "exhausted": other}, fh, indent=1)
    print(f"  {len(cex)} counterexample(s), {len(other)} exhausted, {len(unverified)} not confirmed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
