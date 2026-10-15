#!/usr/bin/env python3
"""Build the Go verification brief, the partial summary.json and the gate
(verify-brief.yml steps "Build the verification brief" and "Gate", issue #126).

Usage: summary.py --art DIR [--tier baseline|standard] [--mutation-threshold 0] [--gate]

Reads go.json and gremlins.json from DIR; writes DIR/verify-brief.md and
DIR/summary.json (fields this workflow owns per
policies/verification/summary.schema.json, tool "verify-go", plus a `gate`
object). Blocking at both tiers: go vet findings, a fuzz crasher, an exported
function on a mapped path with no Fuzz* target. Blocking at standard (advisory
at baseline): staticcheck, nilaway or errcheck findings, a high-risk package
with no rapid/quick property, corpus-hygiene violations. A gremlins score
under a non-zero threshold blocks.
"""

import argparse
import json
import os
import sys


def jload(p, d):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return d


def table(head, rows):
    if not rows:
        return ""
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
                     + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])


def gremlins_score(report):
    """(killed + timed out) / (killed + timed out + lived + not covered); not viable and skipped excluded."""
    if not report:
        return None, {}
    counts = {}
    for f in report.get("files", []):
        for m in f.get("mutations", []):
            counts[m["status"]] = counts.get(m["status"], 0) + 1
    detected = counts.get("KILLED", 0) + counts.get("TIMED OUT", 0)
    undetected = counts.get("LIVED", 0) + counts.get("NOT COVERED", 0)
    return (round(detected / (detected + undetected) * 100, 2) if detected + undetected else None), counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--tier", default="baseline")
    ap.add_argument("--mutation-threshold", type=float, default=0)
    ap.add_argument("--gate", action="store_true")
    args = ap.parse_args()
    ART, standard = args.art, args.tier == "standard"
    go = jload(f"{ART}/go.json", {}) or {}
    score, mc = gremlins_score(jload(f"{ART}/gremlins.json", None))

    M = ["## Verification brief (Go)", ""]
    if not go or not go.get("packages"):
        M += ["No changed Go packages.", ""]
    else:
        def lint(rc, n, what):
            return "_not run_" if rc is None else "clean" if rc == 0 else f"{n} {what}"
        rows = [["go vet", "_not run_" if go["vet"] is None else "clean" if go["vet"] == 0 else f"**{go['vet_lines']} finding(s)**"],
                ["staticcheck", lint(go["staticcheck"], go["staticcheck_lines"], "finding(s)")],
                ["nilaway", lint(go["nilaway"], go["nilaway_lines"], "possible nil panic(s)")],
                ["errcheck", lint(go["errcheck"], go["errcheck_lines"], "unchecked error(s)")],
                ["fuzz targets run", str(go["fuzz_targets"])],
                ["crashers", "**" + ", ".join(f"`{c}`" for c in go["crashers"]) + "**" if go["crashers"] else "none within budget"],
                ["property test files in changed packages", str(go["property_files"])],
                ["mapped exported functions with no Fuzz* target", f"**{len(go['uncovered'])}**" if go["uncovered"] else "0"]]
        if score is not None:
            rows.append(["gremlins mutation score", f"{score}% ({mc.get('KILLED', 0)} killed, {mc.get('LIVED', 0)} lived, "
                         f"{mc.get('NOT COVERED', 0)} not covered, {mc.get('TIMED OUT', 0)} timed out)"])
        M += [table(["Check", "Result"], rows), ""]
        if go["fuzz_targets"] == 0:
            M += ["> No `Fuzz*` target in the changed packages. Fuzzing is Go's counterexample search; "
                  "without a target this PR has no claim to refute.", ""]
        if go["crashers"]:
            M += ["> A crasher is a concrete input, saved under `testdata/fuzz/` and replayed by every "
                  "future `go test`. Commit it with the fix.", "",
                  table(["Crasher", "Reproduce"], [[f"`{c['file']}`", f"`{c['reproduce']}`"] for c in go["crasher_details"][:10]]), ""]
        if go["uncovered"]:
            M += [table(["Function", "Package"], [[f"`{u['file']}:{u['line']}` `{u['name']}`", f"`{u['dir']}`"] for u in go["uncovered"][:20]]), "",
                  "> Every exported function on a mapped path needs a `Fuzz*` target that calls it.", ""]
        if go["high_risk_without_property"]:
            M += ["> High-risk package(s) with no `rapid.Check` or `quick.Check` property: "
                  + ", ".join(f"`{d}`" for d in go["high_risk_without_property"]) + ".", ""]
        if go["hygiene"]:
            M += ["> Corpus hygiene: " + "; ".join(go["hygiene"][:10]) + ".", ""]
    M += ["Rungs and verdicts: docs/verification.md.", "", "<sub>Advisory except where the Gate step says otherwise.</sub>"]
    with open(f"{ART}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")

    fail, warn = [], []
    if go.get("vet"):
        fail.append("go vet reported findings in changed packages")
    if go.get("crashers"):
        fail.append(f"{len(go['crashers'])} Go fuzz crasher(s): a concrete failing input exists")
    if go.get("uncovered"):
        fail.append(f"{len(go['uncovered'])} exported function(s) on mapped paths with no Fuzz* target")
    for tool in ("staticcheck", "nilaway", "errcheck"):
        if go.get(tool):
            (fail if standard else warn).append(f"{tool} reported {go[f'{tool}_lines']} finding(s) in changed packages")
    if go.get("high_risk_without_property"):
        (fail if standard else warn).append(f"{len(go['high_risk_without_property'])} high-risk package(s) with no rapid/quick property")
    if go.get("hygiene"):
        (fail if standard else warn).append(f"{len(go['hygiene'])} corpus-hygiene violation(s) under testdata/fuzz")
    if score is not None and args.mutation_threshold > 0 and score < args.mutation_threshold:
        fail.append(f"mutation score {score}% under the {args.mutation_threshold}% threshold")
    elif score is not None and mc.get("LIVED"):
        warn.append(f"{mc['LIVED']} surviving mutant(s) in the changed packages")

    summary = {"go_vet": go.get("vet"), "go_crashers": len(go.get("crashers", [])) if go else None,
               "go_fuzz_targets": go.get("fuzz_targets"), "counterexamples": 0, "unverified": 0,
               "bare_high_risk": len(go.get("uncovered", [])), "mutation_score": score,
               "tier": args.tier, "strict": standard, "tool": "verify-go", "gate": {"fail": fail, "warn": warn}}
    with open(f"{ART}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"vet={'' if go.get('vet') is None else go['vet']}\ncrashers={len(go.get('crashers', []))}\n"
                     f"fuzz-targets={go.get('fuzz_targets', 0)}\nuncovered={len(go.get('uncovered', []))}\n"
                     f"mutation-score={'' if score is None else score}\nblocking={len(fail)}\n")
    for w in warn:
        print(f"  warn: {w}")
        print(f"::warning title=verify-go::{w}")
    for f in fail:
        print(f"  FAIL: {f}")
        print(f"::error title=verify-go::{f}")
    print(f"\n{len(fail)} blocking, {len(warn)} advisory")
    return 1 if (args.gate and fail) else 0


if __name__ == "__main__":
    sys.exit(main())
