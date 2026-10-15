#!/usr/bin/env python3
"""Lean build and Kani report, brief and gate (issue #131).

Usage:
  lean.py lean  --log build.txt --rc N --root PREFIX --output lean.json
  lean.py kani  --log kani.txt --rc N --crate DIR --output kani-<crate>.json
  lean.py brief --art DIR [--gate]

lean: parses `lake build --wfail` output ("error: <file>:<line>:<col>: msg",
"warning: <file>:<line>:<col>: declaration uses 'sorry'"); with --wfail a
sorry fails the build, and it is reported as its own kind so the brief can
say "unfinished proof" rather than "error". Annotations point into the
repository (--root is the project's path from the repository root).
kani: parses `cargo kani` output ("Checking harness <name>...",
"VERIFICATION:- SUCCESSFUL|FAILED", "Complete - N successfully verified
harnesses, M failures, T total").
brief: writes verify-brief.md and summary.json (tool "verify-lean"; `lean`
and `kani` are outcomes success | failure | null as in
policies/verification/summary.schema.json) and gates on a failed build or a
failed harness. Stdlib only.
"""

import argparse
import json
import os
import re
import sys

# Lake prints "error: <file>:<l>:<c>: msg"; Lean itself prints "<file>:<l>:<c>: error: msg"
MSG = re.compile(r"^(?P<level>error|warning): (?P<file>[^:\n]+\.lean):(?P<line>\d+):(?P<col>\d+): (?P<msg>.*)$")
MSG2 = re.compile(r"^(?P<file>[^:\n]+\.lean):(?P<line>\d+):(?P<col>\d+): (?P<level>error|warning): (?P<msg>.*)$")


def lean(a):
    issues = []
    for l in open(a.log, encoding="utf-8", errors="ignore").read().splitlines():
        m = MSG.match(l.strip()) or MSG2.match(l.strip())
        if not m:
            continue
        d = m.groupdict()
        kind = "sorry" if "declaration uses `sorry`" in d["msg"] or "declaration uses 'sorry'" in d["msg"] else d["level"]
        f = os.path.join(a.root, d["file"]) if a.root else d["file"]
        issues.append({"file": f, "line": int(d["line"]), "col": int(d["col"]), "kind": kind, "message": d["msg"][:300]})
        if kind != "warning":
            title = "unfinished proof (sorry)" if kind == "sorry" else "Lean error"
            print(f"::error file={f},line={d['line']},col={d['col']},title={title}::{d['msg'][:300]}")
    if a.rc != 0 and not any(i["kind"] in ("error", "sorry") for i in issues):
        issues.append({"file": a.root or ".", "line": 1, "col": 1, "kind": "error",
                       "message": f"lake build exited {a.rc} without a located error (see lake-build.txt)"})
        print(f"::error title=Lean error::lake build exited {a.rc} without a located error (see the build log)")
    out = {"rc": a.rc, "outcome": "success" if a.rc == 0 else "failure", "issues": issues}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"  lake build --wfail rc={a.rc}: {sum(1 for i in issues if i['kind'] == 'error')} error(s), "
          f"{sum(1 for i in issues if i['kind'] == 'sorry')} sorry, {sum(1 for i in issues if i['kind'] == 'warning')} warning(s)")
    return 0


def kani(a):
    txt = open(a.log, encoding="utf-8", errors="ignore").read()
    harnesses, cur = [], None
    for l in txt.splitlines():
        m = re.match(r"^Checking harness (\S+)\.\.\.", l)
        if m:
            cur = {"name": m.group(1), "result": None}
            harnesses.append(cur)
        m = re.search(r"VERIFICATION:- (SUCCESSFUL|FAILED)", l)
        if m and cur is not None:
            cur["result"] = m.group(1).lower()
    m = re.search(r"Complete - (\d+) successfully verified harnesses?, (\d+) failures?, (\d+) total", txt)
    failed_checks = re.findall(r"^Check \d+: (\S+)\n\s+- Status: FAILURE\n\s+- Description: \"([^\"]*)\"", txt, re.M)
    out = {"crate": a.crate, "rc": a.rc, "harnesses": harnesses,
           "verified": int(m.group(1)) if m else sum(1 for h in harnesses if h["result"] == "successful"),
           "failures": int(m.group(2)) if m else sum(1 for h in harnesses if h["result"] == "failed"),
           "failed_checks": [{"check": c, "description": d} for c, d in failed_checks][:20]}
    if a.rc != 0 and not out["failures"]:
        out["failures"] = 1
        out["failed_checks"].append({"check": "cargo kani", "description": f"exited {a.rc} without a harness result (build or setup error)"})
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    for c in out["failed_checks"]:
        print(f"::error file={a.crate}/Cargo.toml,title=Kani failure::{c['check']}: {c['description']}")
    print(f"  {a.crate}: {out['verified']} harness(es) verified, {out['failures']} failure(s)")
    return 0


def brief(a):
    art = a.art
    def jl(p):
        try:
            with open(p) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None
    ln = jl(f"{art}/lean.json")
    ks = [jl(os.path.join(art, f)) for f in sorted(os.listdir(art)) if f.startswith("kani-") and f.endswith(".json")]
    M = ["## Verification brief (Lean, Kani)", ""]
    if ln is not None:
        sorries = [i for i in ln["issues"] if i["kind"] == "sorry"]
        errors = [i for i in ln["issues"] if i["kind"] == "error"]
        M += ["### Lean 4", "", "`lake build --wfail`: " + ("proven" if ln["outcome"] == "success" else "**failed**")
              + f" ({len(errors)} error(s), {len(sorries)} unfinished proof(s))", ""]
        if errors or sorries:
            M += ["| Where | Kind | Message |", "|---|---|---|"]
            M += [f"| `{i['file']}:{i['line']}` | {'sorry' if i['kind'] == 'sorry' else 'error'} | {i['message'][:140].replace('|', '/')} |"
                  for i in (errors + sorries)[:25]]
            M += [""]
        M += ["> The kernel checked the proofs; a reviewer checks the statements. Each theorem a PR adds or changes "
              "must say what its acceptance criterion says (docs/verification.md, statement review).", ""]
    if ks:
        M += ["### Kani", "", "| Crate | Verified | Failures |", "|---|---|---|"]
        M += [f"| `{k['crate']}` | {k['verified']} | " + (f"**{k['failures']}**" if k["failures"] else "0") + " |" for k in ks]
        M += [""]
        fc = [(k["crate"], c) for k in ks for c in k["failed_checks"]]
        if fc:
            M += ["| Crate | Check | Description |", "|---|---|---|"]
            M += [f"| `{cr}` | `{c['check']}` | {c['description'][:140]} |" for cr, c in fc[:20]]
            M += ["", "> A failed Kani check is a reachable panic, overflow or failed assertion within the harness bounds.", ""]
    if ln is None and not ks:
        M += ["No Lean project and no `kani::proof` harness in scope.", ""]
    M += ["Rungs and verdicts: docs/verification.md."]
    with open(f"{art}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")
    fail = []
    if ln is not None and ln["outcome"] == "failure":
        fail.append("Lean build failed or a proof is unfinished (sorry)")
    if any(k["failures"] for k in ks):
        fail.append("Kani found a reachable panic or failed harness")
    kani_outcome = None if not ks else ("failure" if any(k["failures"] for k in ks) else "success")
    summary = {"lean": None if ln is None else ln["outcome"], "kani": kani_outcome, "counterexamples": 0,
               "unverified": 0 if ln is None else sum(1 for i in ln["issues"] if i["kind"] == "sorry"),
               "bare_high_risk": 0, "strict": True, "tool": "verify-lean", "gate": {"fail": fail, "warn": []}}
    with open(f"{art}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"lean={summary['lean'] or ''}\nkani={kani_outcome or ''}\nblocking={len(fail)}\n")
    for f in fail:
        print(f"  FAIL: {f}")
    print(f"\n{len(fail)} blocking")
    return 1 if (a.gate and fail) else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("lean"); p.add_argument("--log", required=True); p.add_argument("--rc", type=int, required=True)
    p.add_argument("--root", default=""); p.add_argument("--output", required=True)
    k = sub.add_parser("kani"); k.add_argument("--log", required=True); k.add_argument("--rc", type=int, required=True)
    k.add_argument("--crate", required=True); k.add_argument("--output", required=True)
    b = sub.add_parser("brief"); b.add_argument("--art", required=True); b.add_argument("--gate", action="store_true")
    a = ap.parse_args()
    return {"lean": lean, "kani": kani, "brief": brief}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
