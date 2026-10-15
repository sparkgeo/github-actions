#!/usr/bin/env python3
"""Build the TypeScript verification brief, the partial summary.json and the
gate (verify-brief.yml steps "Build the verification brief" and "Gate", issue
#127).

Usage: summary.py --art DIR [--tier baseline|standard] [--strict] [--mutation-threshold 0]
                  [--eslint-rc N] [--gate]

Reads ts.json, entrypoints.json, eslint.json, xstate.json and
reports/mutation.json from DIR; writes DIR/verify-brief.md and DIR/summary.json
(the fields this workflow owns per policies/verification/summary.schema.json,
tool "verify-ts", plus a `gate` object). Blocking: ESLint errors in changed
files (both tiers); tsc errors in changed files under the strictest flags when
--strict or tier standard; at tier standard an unvalidated exported entry point
on a mapped path, a high-risk file with no fast-check property, a failed XState
path; a mutation score under a non-zero threshold. Everything else advisory.
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


def stryker_score(report):
    """Stryker's mutation score: detected / (detected + undetected), errors and ignored excluded."""
    if not report:
        return None, {}
    counts = {}
    for f in report.get("files", {}).values():
        for m in f.get("mutants", []):
            counts[m["status"]] = counts.get(m["status"], 0) + 1
    detected = counts.get("Killed", 0) + counts.get("Timeout", 0)
    undetected = counts.get("Survived", 0) + counts.get("NoCoverage", 0)
    return (round(detected / (detected + undetected) * 100, 2) if detected + undetected else None), counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--tier", default="baseline")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--mutation-threshold", type=float, default=0)
    ap.add_argument("--eslint-rc", type=int, default=-1, help="-1: not run")
    ap.add_argument("--gate", action="store_true")
    args = ap.parse_args()
    ART, standard = args.art, args.tier == "standard"

    ts = jload(f"{ART}/ts.json", {}) or {}
    ep = jload(f"{ART}/entrypoints.json", None)
    es = jload(f"{ART}/eslint.json", None)
    xs = jload(f"{ART}/xstate.json", None)
    score, mcounts = stryker_score(jload(f"{ART}/reports/mutation.json", None))

    mapped = set(ts.get("mapped", []))
    unvalidated = [(f["file"], fn) for f in (ep or []) if f["file"] in mapped
                   for fn in f["functions"] if fn["name"] in f["unvalidated"]]
    eslint_errors = sum(r.get("errorCount", 0) for r in (es or []))
    eslint_rows = [(r["filePath"], m) for r in (es or []) for m in r.get("messages", []) if m.get("severity") == 2]
    no_prop = ts.get("high_risk_without_property", [])
    x_fail = [(x["file"], x["machine"], f) for x in (xs or []) for f in x["failures"]]
    x_unreached = [(x["machine"], s) for x in (xs or []) for s in x["unreached"]]
    x_value_only = [x["machine"] for x in (xs or []) if x["bound"] == "value-only"]

    M = ["## Verification brief (TypeScript)", ""]
    if not ts:
        M += ["No changed TypeScript or JavaScript files.", ""]
    else:
        tsc_txt = ("no tsconfig.json" if ts["tsc"] == -1 else
                   "clean under `--strict --noUncheckedIndexedAccess --exactOptionalPropertyTypes`" if ts["tsc"] == 0 else
                   f"**{ts['tsc_errors_changed']} error(s) in changed files** ({ts['tsc_errors_all']} across the repo)")
        rows = [["tsc, strictest flags", tsc_txt],
                ["ESLint (typescript-eslint strict)", "_not run_" if args.eslint_rc < 0 else "clean" if not eslint_errors else f"**{eslint_errors} error(s)**"],
                ["changed test files using fast-check", f"{len(ts['property_files'])} of {ts['test_files']}"],
                ["changed files declaring zod/valibot schemas", str(ts["schema_files"])]]
        if ep is not None:
            rows.append(["exported entry points on mapped paths without a schema parse", f"**{len(unvalidated)}**" if unvalidated else "0"])
            rows.append(["branded types in checked files", str(sum(f["branded"] for f in ep))])
        if ts.get("high_risk"):
            rows.append(["high-risk files with no fast-check property", f"**{len(no_prop)}**" if no_prop else "0"])
        if xs is not None:
            rows.append(["XState paths executed", f"{sum(x['executed'] for x in xs)} of {sum(x['paths'] for x in xs)} over {len(xs)} machine(s)"
                         + (f"; **{len(x_fail)} failed**" if x_fail else "")])
        if score is not None:
            rows.append(["Stryker mutation score", f"{score}% ({mcounts.get('Killed', 0)} killed, {mcounts.get('Survived', 0)} survived, "
                         f"{mcounts.get('NoCoverage', 0)} no coverage, {mcounts.get('Timeout', 0)} timed out)"])
        M += [table(["Check", "Result"], rows), ""]
        if eslint_rows:
            M += ["<details><summary>ESLint errors</summary>", "",
                  table(["Where", "Rule", "Message"], [[f"`{os.path.relpath(p)}:{m.get('line', '?')}`", m.get("ruleId") or "", m.get("message", "")[:120]] for p, m in eslint_rows[:20]]),
                  "", "</details>", ""]
        if unvalidated:
            M += ["> An exported function taking `unknown`, `any` or an untyped parameter on a mapped path is an entry point. "
                  "Parse it with a zod or valibot schema before use, or type the parameter.", "",
                  table(["Entry point", "Untrusted parameters"], [[f"`{f}:{fn['line']}` `{fn['name']}`", ", ".join(fn["untrusted_params"])] for f, fn in unvalidated[:20]]), ""]
        if no_prop:
            M += ["> No test file in the project imports these high-risk modules and uses fast-check: "
                  + ", ".join(f"`{f}`" for f in no_prop[:10]) + ". One property per acceptance criterion.", ""]
        if x_fail:
            M += ["### XState paths that failed", "",
                  table(["Machine", "Path", "Error"], [[f"`{m}`", p["path"], p["error"][:140].replace("\n", " ")] for _, m, p in x_fail[:15]]), ""]
        if x_unreached:
            M += ["> States no generated path reaches: " + ", ".join(f"`{m}.{s}`" for m, s in x_unreached[:15])
                  + ". Either dead, or reachable only through context the traversal bound cut off.", ""]
        if x_value_only:
            M += ["> " + ", ".join(f"`{m}`" for m in x_value_only) + ": traversal exceeded the state limit and was keyed on the "
                  "state value only, so context-dependent guards may hide paths. Export `<machineName>Graph` with a `stopWhen` bound.", ""]
        M += ["> TypeScript has no symbolic checker or verifier. Strict types and `fast-check` properties are "
              "its ceiling; anything needing a proof goes through Dafny compiled to JavaScript.", ""]
    M += ["Rungs and verdicts: docs/verification.md.", "",
          "<sub>Advisory except where the Gate step says otherwise.</sub>"]
    with open(f"{ART}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")

    fail, warn = [], []
    errs = ts.get("tsc_errors_changed") or 0
    if errs:
        (fail if (args.strict or standard) else warn).append(f"{errs} TypeScript error(s) in changed files under the strictest flags")
    if eslint_errors:
        fail.append(f"{eslint_errors} ESLint error(s) in changed files")
    if unvalidated:
        (fail if standard else warn).append(f"{len(unvalidated)} exported entry point(s) on mapped paths take untrusted input without a schema parse")
    if no_prop:
        (fail if standard else warn).append(f"{len(no_prop)} high-risk file(s) with no fast-check property")
    if x_fail:
        fail.append(f"{len(x_fail)} XState path(s) failed when executed")
    if x_unreached:
        warn.append(f"{len(x_unreached)} XState state(s) unreached by any generated path")
    if score is not None and args.mutation_threshold > 0 and score < args.mutation_threshold:
        fail.append(f"mutation score {score}% under the {args.mutation_threshold}% threshold")
    elif score is not None and mcounts.get("Survived"):
        warn.append(f"{mcounts['Survived']} surviving mutant(s) in the changed modules")

    summary = {"ts_errors_changed": ts.get("tsc_errors_changed"), "ts_property_files": len(ts.get("property_files", [])) if ts else None,
               "counterexamples": 0, "unverified": 0, "bare_high_risk": len(no_prop),
               "eslint_errors": None if args.eslint_rc < 0 else eslint_errors,
               "unvalidated_entry_points": None if ep is None else len(unvalidated),
               "xstate_paths": None if xs is None else sum(x["paths"] for x in xs),
               "xstate_failures": None if xs is None else len(x_fail),
               "mutation_score": score, "tier": args.tier, "strict": args.strict, "tool": "verify-ts",
               "gate": {"fail": fail, "warn": warn}}
    with open(f"{ART}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"ts-errors-changed={errs}\neslint-errors={eslint_errors}\nunvalidated={len(unvalidated)}\n"
                     f"xstate-failures={len(x_fail)}\nmutation-score={'' if score is None else score}\nblocking={len(fail)}\n")
    for w in warn:
        print(f"  warn: {w}")
        print(f"::warning title=verify-ts::{w}")
    for f in fail:
        print(f"  FAIL: {f}")
        print(f"::error title=verify-ts::{f}")
    print(f"\n{len(fail)} blocking, {len(warn)} advisory")
    return 1 if (args.gate and fail) else 0


if __name__ == "__main__":
    sys.exit(main())
