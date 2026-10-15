#!/usr/bin/env python3
"""Build the Python verification brief, the partial summary.json and gate on
it (verify-brief.yml steps "Build the verification brief" and "Gate", issue
#125; the mutation section follows review-brief.yml job "mutation").

Usage: summary.py --art DIR [--tier baseline|standard] [--strict] [--per-condition 45]
                  [--mutation-threshold 0] [--mypy-rc N] [--pytest-rc N] [--gate]

Reads census.json, crosshair.json, diffbehavior.json, mutmut-cicd-stats.json and
status/* from DIR; writes DIR/verify-brief.md and DIR/summary.json (the fields
this workflow owns per policies/verification/summary.schema.json, tool
"verify-python"). With --gate exits 1 when: a CrossHair counterexample exists,
mypy --strict or `pytest -m property` failed, an uncontracted high-risk function
exists and --strict, a high-risk contract is not confirmed at tier standard, or
the mutation score is under a non-zero --mutation-threshold. Everything else
is advisory.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--tier", default="baseline")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--per-condition", default="45")
    ap.add_argument("--mutation-threshold", type=float, default=0)
    ap.add_argument("--mypy-rc", type=int, default=-1, help="-1: not run")
    ap.add_argument("--pytest-rc", type=int, default=-1, help="-1: not run; 5: no property tests collected")
    ap.add_argument("--gate", action="store_true")
    args = ap.parse_args()
    ART = args.art

    def status(name):
        try:
            with open(f"{ART}/status/{name}") as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            return None

    census = jload(f"{ART}/census.json", [])
    ch = jload(f"{ART}/crosshair.json", {"counterexamples": [], "unverified": [], "exhausted": []})
    dbh = jload(f"{ART}/diffbehavior.json", None)
    mut = jload(f"{ART}/mutmut-cicd-stats.json", None)
    cex, unv, exh = ch["counterexamples"], ch["unverified"], ch.get("exhausted", [])
    contracted = [r for r in census if r["contracts"]]
    bare_hr = [r for r in census if r["high_risk"] and not r["contracts"]]
    opaque = [r for r in census if r.get("opaque")]
    high_risk_files = {r["file"] for r in census if r["high_risk"]}
    unv_hr = [d for d in unv if d["file"] in high_risk_files]
    score = None
    if mut:
        tested = int(mut.get("total", 0)) - int(mut.get("skipped", 0))
        score = None if tested <= 0 else round((int(mut.get("killed", 0)) + int(mut.get("timeout", 0))) / tested * 100, 1)

    M = ["## Verification brief (Python)", ""]
    M += ["### Contract census", ""]
    if not census:
        M += ["No public functions changed in non-test Python files.", ""]
    else:
        M += [f"{len(contracted)} of {len(census)} changed public function(s) carry a contract.", "",
              table(["Function", "Contract", "High-risk path", "Opaque boundary"],
                    [[f"`{r['file']}:{r['line']}` `{r['name']}`",
                      ", ".join(r["contracts"]) or "**none**",
                      "yes" if r["high_risk"] else "",
                      ", ".join(r.get("opaque", []))] for r in sorted(census, key=lambda r: (not r["high_risk"], bool(r["contracts"])))[:25]]), ""]
        if bare_hr:
            M += [f"> {len(bare_hr)} function(s) on high-risk paths have no postcondition. Nothing below can "
                  "say anything about them: a checker needs a claim to refute.", ""]
        if opaque:
            M += [f"> {len(opaque)} function(s) call into a C extension (GEOS, PROJ, NumPy, GDAL). CrossHair "
                  "cannot see inside it: a \"Not confirmed\" there is an opaque boundary, not a failure. "
                  "Keep the contract on the pure wrapper around the call.", ""]

    M += ["### Static invariants (mypy --strict)", ""]
    M += ["_Not run._" if args.mypy_rc < 0 else "clean" if args.mypy_rc == 0 else "**errors** (see the job log)", ""]

    M += ["### CrossHair", ""]
    if status("crosshair") is None:
        M += ["_Not run._", ""]
    else:
        M += [f"{len(cex)} counterexample(s); {len(exh)} contract(s) confirmed over all paths; "
              f"{len(unv)} not confirmed within {args.per_condition}s per condition.", ""]
        if cex:
            M += ["A counterexample is a concrete input on which the stated contract is false. "
                  "Either the contract or the code is wrong; the PR decides which.", "",
                  table(["Where", "Counterexample"], [[f"`{d['file']}:{d['line']}`", d["msg"][:160]] for d in cex[:12]]), ""]
        if unv:
            M += ["<details><summary>Not confirmed (budget or opaque call)</summary>", "",
                  table(["Where", "Reason"], [[f"`{d['file']}:{d['line']}`", d["msg"][:140]] for d in unv[:15]]),
                  "", "</details>", ""]
        if not cex and contracted:
            M += ["> \"Confirmed over all paths\" means CrossHair exhausted the symbolic paths it could "
                  "model: as strong as it gets short of a proof. \"Not confirmed\" is bounded confidence; "
                  "raise `crosshair-per-condition-timeout` or move the contract to a pure boundary.", ""]

    M += ["### Properties (pytest -m property)", ""]
    M += ["_Not run._" if args.pytest_rc < 0 else "passed" if args.pytest_rc == 0 else
          "no property tests collected" if args.pytest_rc == 5 else "**failed** (see the job log)", ""]

    if dbh is not None:
        M += ["### Semantic diff against base", ""]
        M += [table(["Function", "Verdict", "Detail"],
                    [[f"`{d['file']}` `{d['function']}`", d["verdict"], d["detail"][:120].replace("\n", " ")]
                     for d in sorted(dbh, key=lambda d: d["verdict"] != "differs")[:15]]) or "_Nothing comparable._", ""]

    if mut is not None:
        M += ["### Mutation testing", ""]
        if score is None:
            M += ["No mutants in the changed functions.", ""]
        else:
            M += [f"Score {score}%: {mut.get('killed', 0)} killed, {mut.get('survived', 0)} survived, "
                  f"{mut.get('timeout', 0)} timed out of {mut.get('total', 0)} mutant(s).", "",
                  "A survivor means the code was altered and every test still passed. "
                  "Those lines are executed by the suite but not asserted on. "
                  "Reproduce locally: `mutmut browse`, or `mutmut apply <mutant>`.", ""]

    M += ["### What this workflow did not establish", "",
          "- That a contract states what the acceptance criterion meant.",
          "- Anything about functions with no contract.",
          "- Anything inside C or cgo extensions (GEOS, NumPy, PROJ) called from a contracted function.",
          "- That the implementation matches its TLA+ or Lean model.", "",
          "Rungs and verdicts: docs/verification.md.", "",
          "<sub>Advisory except where the Gate step says otherwise.</sub>"]
    with open(f"{ART}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")
    summary = {"changed_public": len(census), "contracted": len(contracted),
               "bare_high_risk": len(bare_hr), "counterexamples": len(cex), "unverified": len(unv),
               "exhausted": len(exh),
               "diff_differs": sum(1 for d in (dbh or []) if d["verdict"] == "differs") if dbh is not None else None,
               "mutation_score": score, "mypy": None if args.mypy_rc < 0 else args.mypy_rc,
               "properties": None if args.pytest_rc < 0 else args.pytest_rc,
               "opaque": len(opaque), "tier": args.tier,
               "strict": args.strict, "tool": "verify-python"}
    s = summary
    fail, warn = [], []
    if s["counterexamples"]:
        fail.append(f"{s['counterexamples']} CrossHair counterexample(s): a stated contract is false")
    if args.mypy_rc > 0:
        fail.append("mypy --strict reported errors on mapped paths")
    if args.pytest_rc not in (-1, 0, 5):
        fail.append("pytest -m property failed")
    if s["bare_high_risk"]:
        (fail if s["strict"] else warn).append(
            f"{s['bare_high_risk']} changed public function(s) on high-risk paths with no contract")
    if unv_hr and args.tier == "standard":
        fail.append(f"{len(unv_hr)} contract(s) on high-risk paths not confirmed within budget (tier standard)")
    if s["unverified"]:
        warn.append(f"{s['unverified']} contract(s) not confirmed within budget")
    if s["diff_differs"]:
        warn.append(f"{s['diff_differs']} refactored function(s) differ from base on some input")
    if score is not None and args.mutation_threshold > 0 and score < args.mutation_threshold:
        fail.append(f"mutation score {score}% under the {args.mutation_threshold}% threshold")
    elif score is not None and mut.get("survived"):
        warn.append(f"{mut['survived']} surviving mutant(s) in the changed functions")
    # the workflow posts the brief first and gates on summary.json last, so a
    # red build always arrives with its explanation attached to the PR
    summary["gate"] = {"fail": fail, "warn": warn}
    with open(f"{ART}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"counterexamples={len(cex)}\nunverified={len(unv)}\nbare-high-risk={len(bare_hr)}\n"
                     f"mutation-score={'' if score is None else score}\nblocking={len(fail)}\n")
    for w in warn:
        print(f"  warn: {w}")
        print(f"::warning title=verify-python::{w}")
    for f in fail:
        print(f"  FAIL: {f}")
        print(f"::error title=verify-python::{f}")
    print(f"\n{len(fail)} blocking, {len(warn)} advisory")
    return 1 if (args.gate and fail) else 0


if __name__ == "__main__":
    sys.exit(main())
