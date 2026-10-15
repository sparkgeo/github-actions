#!/usr/bin/env python3
"""Classify govulncheck JSON output by reachability and gate on it (issue #180).

Usage: report.py --input govulncheck.json [--fail-on reachable|none]
                 [--working-directory .] [--output report.json]

govulncheck -format json streams objects: config, progress, osv (one per
advisory in the database that touches a required module) and finding. A
finding's trace is one frame per hop: module-level findings carry only
{module}, package-level ones {module, package}, symbol-level ones a frame with
{function} and the position in the calling code. One advisory (OSV id) is
reported at every level it reaches, so this script keeps the deepest level
per id (SecOps plan Step 3 Baseline, Step 25 reachability row):

  reachable  a vulnerable function is called: the gate finding
  imported   the vulnerable package is imported, no vulnerable call: one SLA
             row down, informational
  module     the module is required, the package is not imported: informational

Exit 1 when any advisory is reachable and --fail-on is reachable; 0 otherwise.
Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import sys

LEVELS = {"module": 0, "imported": 1, "reachable": 2}


def stream(path):
    dec = json.JSONDecoder()
    raw = open(path).read()
    i = 0
    while i < len(raw):
        while i < len(raw) and raw[i].isspace():
            i += 1
        if i >= len(raw):
            break
        obj, i = dec.raw_decode(raw, i)
        yield obj


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--fail-on", choices=["reachable", "none"], default="reachable")
    ap.add_argument("--working-directory", default=".")
    ap.add_argument("--output")
    args = ap.parse_args()

    advisories, findings = {}, {}
    for obj in stream(args.input):
        if "osv" in obj:
            v = obj["osv"]
            advisories[v["id"]] = {"aliases": v.get("aliases") or [], "summary": v.get("summary") or "",
                                   "url": f'https://pkg.go.dev/vuln/{v["id"]}'}
        elif "finding" in obj:
            f = obj["finding"]
            trace = f.get("trace") or []
            if any(t.get("function") for t in trace):
                level = "reachable"
            elif any(t.get("package") for t in trace):
                level = "imported"
            else:
                level = "module"
            cur = findings.setdefault(f["osv"], {"level": "module", "module": trace[0].get("module") if trace else None,
                                                  "package": None, "fixed_version": f.get("fixed_version"), "calls": []})
            if LEVELS[level] >= LEVELS[cur["level"]]:
                cur["level"] = level
            for t in trace:
                if t.get("package") and not cur["package"]:
                    cur["package"] = t["package"]
            if level == "reachable":
                vuln = trace[0]
                caller = next((t for t in trace[1:] if t.get("position")), None)
                pos = (caller or {}).get("position") or {}
                cur["calls"].append({
                    "vulnerable": f'{vuln.get("package", "")}.{vuln.get("function", "")}',
                    "caller": f'{(caller or {}).get("package", "")}.{(caller or {}).get("function", "")}',
                    "file": pos.get("filename"), "line": pos.get("line"), "column": pos.get("column")})

    rows = []
    for osv_id, f in sorted(findings.items(), key=lambda kv: (-LEVELS[kv[1]["level"]], kv[0])):
        a = advisories.get(osv_id, {"aliases": [], "summary": "", "url": f"https://pkg.go.dev/vuln/{osv_id}"})
        rows.append({"id": osv_id, "aliases": a["aliases"], "summary": a["summary"], "url": a["url"], **f})

    counts = {k: sum(1 for r in rows if r["level"] == k) for k in LEVELS}
    for r in rows:
        if r["level"] != "reachable":
            continue
        for c in r["calls"] or [{}]:
            loc = ""
            if c.get("file"):
                path = os.path.normpath(os.path.join(args.working_directory, c["file"]))
                loc = f"file={path},line={c.get('line') or 1},col={c.get('column') or 1},"
            print(f'::error {loc}title=govulncheck {r["id"]}::{r["summary"]} ({", ".join(r["aliases"]) or "no CVE"}); '
                  f'{c.get("caller", "")} calls {c.get("vulnerable", "")}; fixed in {r["module"]}@{r["fixed_version"]}')
    for r in rows:
        if r["level"] == "imported":
            print(f'::notice title=govulncheck {r["id"]} (imported, not called)::{r["summary"]}; {r["package"]} is imported but no vulnerable '
                  f'function is called; one SLA row down; fixed in {r["module"]}@{r["fixed_version"]}')

    summary = [f'## govulncheck: {counts["reachable"]} reachable, {counts["imported"]} imported but not called, {counts["module"]} module-only', ""]
    if rows:
        summary += ["| Advisory | Level | Module | Package | Fixed in | Called from |", "|---|---|---|---|---|---|"]
        for r in rows:
            called = "; ".join(f'{c["caller"]} ({c["file"]}:{c["line"]})' if c.get("file") else c["caller"] for c in r["calls"]) or "-"
            summary.append(f'| [{r["id"]}]({r["url"]}) {", ".join(r["aliases"])} | **{r["level"]}** | {r["module"]} | {r["package"] or "-"} | {r["fixed_version"] or "-"} | {called} |')
    summary += ["", "Reachable advisories block when `fail-on` is `reachable`. Imported and module-only advisories are informational "
                "and sit one SLA row lower (SecOps plan Step 25, reachability). govulncheck carries no CVSS; the CVSS-based gate "
                "for `go.sum` is `dep-scan-app.yml`."]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f'reachable-count={counts["reachable"]}\nimported-count={counts["imported"]}\nmodule-count={counts["module"]}\n')
    if args.output:
        with open(args.output, "w") as f:
            json.dump({"counts": counts, "findings": rows}, f, indent=1)
            f.write("\n")
    if args.fail_on == "reachable" and counts["reachable"]:
        print(f'::error title=govulncheck::{counts["reachable"]} reachable vulnerabilit{"y" if counts["reachable"] == 1 else "ies"}; fix or pin the fixed version')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
