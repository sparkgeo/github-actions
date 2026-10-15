#!/usr/bin/env python3
"""Dafny verification report and compiled-output drift check (issue #128).

Usage:
  dafny.py report --log dafny.txt --rc N --output dafny.json
  dafny.py drift  --generated DIR --committed DIR --target py|go|js --output drift.json
  dafny.py brief  --art DIR [--gate]

report: parses `dafny verify` output ("<file>(<line>,<col>): Error: <msg>"
and the "Dafny program verifier finished with N verified, M errors, K time
outs" line), prints one ::error annotation per failure and writes dafny.json.
drift: compares the freshly translated tree with the committed directory;
files the translation produces must exist and match byte for byte, files
only in the committed directory (go.mod, consumer tests, package.json) are
allowed; *.dtr translation records and __pycache__ are ignored.
brief: writes verify-brief.md and summary.json (tool "verify-dafny", the
`dafny` field is the verify exit code) and gates on a failed verification or
any drift. Stdlib only.
"""

import argparse
import filecmp
import json
import os
import re
import sys

ERR = re.compile(r"^(?P<file>[^(\n]+)\((?P<line>\d+),(?P<col>\d+)\): Error: (?P<msg>.*)$")
FIN = re.compile(r"finished with (?P<v>\d+) verified, (?P<e>\d+) errors?(?:, (?P<t>\d+) time outs?)?")
IGNORE = ("__pycache__",)


def report(a):
    fails, verified, errors, timeouts = [], 0, 0, 0
    with open(a.log, encoding="utf-8", errors="ignore") as fh:
        for l in fh:
            l = l.rstrip()
            m = ERR.match(l)
            if m:
                d = m.groupdict()
                d["line"], d["col"] = int(d["line"]), int(d["col"])
                d["kind"] = "timeout" if "timed out" in d["msg"] else "error"
                fails.append(d)
                print(f"::error file={d['file']},line={d['line']},col={d['col']},title=dafny {d['kind']}::{d['msg'][:300]}")
            m = FIN.search(l)
            if m:
                verified += int(m.group("v")); errors += int(m.group("e")); timeouts += int(m.group("t") or 0)
    out = {"rc": a.rc, "verified": verified, "errors": errors, "timeouts": timeouts, "failures": fails}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"  dafny verify rc={a.rc}: {verified} verified, {errors} error(s), {timeouts} time out(s)")
    return 0


def walk(root):
    out = set()
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in IGNORE]
        for f in files:
            if not f.endswith(".dtr"):
                out.add(os.path.relpath(os.path.join(d, f), root))
    return out


def drift(a):
    gen, com = walk(a.generated), walk(a.committed) if os.path.isdir(a.committed) else set()
    missing = sorted(gen - com)
    changed = sorted(f for f in gen & com
                     if not filecmp.cmp(os.path.join(a.generated, f), os.path.join(a.committed, f), shallow=False))
    out = {"target": a.target, "committed": a.committed, "generated_files": len(gen), "missing": missing, "changed": changed}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    for f in missing + changed:
        print(f"::error file={os.path.join(a.committed, f)},title=dafny drift ({a.target})::compiled output out of date; re-run the translation and commit")
    print(f"  {a.target}: {len(gen)} generated file(s), {len(missing)} missing, {len(changed)} different in {a.committed}")
    return 0


def brief(a):
    art = a.art
    try:
        with open(f"{art}/dafny.json") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        d = None
    drifts = []
    for f in sorted(os.listdir(art)):
        if f.startswith("drift-") and f.endswith(".json"):
            with open(os.path.join(art, f)) as fh:
                drifts.append(json.load(fh))
    M = ["## Verification brief (Dafny)", ""]
    if d is None:
        M += ["_Verification not run._", ""]
    else:
        M += [f"`dafny verify`: {d['verified']} verified, {d['errors']} error(s), {d['timeouts']} time out(s)"
              + (" (proven)" if d["rc"] == 0 else " (**failed**)"), ""]
        if d["failures"]:
            M += ["| Where | Kind | Message |", "|---|---|---|"]
            M += [f"| `{x['file']}:{x['line']}` | {x['kind']} | {x['msg'][:140]} |" for x in d["failures"][:20]]
            M += ["", "> A time out is not a counterexample: the solver gave up. Split the proof with a lemma "
                  "(docs/verification.md, \"SMT timeouts\") before raising the limit.", ""]
    if drifts:
        M += ["| Target | Committed | Generated files | Missing | Different |", "|---|---|---|---|---|"]
        M += [f"| {x['target']} | `{x['committed']}` | {x['generated_files']} | {len(x['missing'])} | {len(x['changed'])} |" for x in drifts]
        if any(x["missing"] or x["changed"] for x in drifts):
            M += ["", "> The committed compiled code does not match the Dafny source. Run the translation "
                  "(command in the job summary) and commit the output.", ""]
        M += [""]
    M += ["> Dafny results are proofs of the Dafny source, not of hand-written code in the target languages.", "",
          "Rungs and verdicts: docs/verification.md."]
    with open(f"{art}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")
    fail = []
    if d is not None and d["rc"] != 0:
        fail.append(f"Dafny verification failed: {d['errors']} error(s), {d['timeouts']} time out(s)")
    for x in drifts:
        if x["missing"] or x["changed"]:
            fail.append(f"{x['target']} compiled output in {x['committed']} is out of date ({len(x['missing'])} missing, {len(x['changed'])} different)")
    summary = {"dafny": None if d is None else d["rc"], "counterexamples": 0, "unverified": 0 if d is None else d["timeouts"],
               "bare_high_risk": 0, "strict": True, "tool": "verify-dafny",
               "drift": sum(len(x["missing"]) + len(x["changed"]) for x in drifts), "gate": {"fail": fail, "warn": []}}
    with open(f"{art}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"dafny={'' if d is None else d['rc']}\ndrift={summary['drift']}\nblocking={len(fail)}\n")
    for f in fail:
        print(f"  FAIL: {f}")
        print(f"::error title=verify-dafny::{f}")
    print(f"\n{len(fail)} blocking")
    return 1 if (a.gate and fail) else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report"); r.add_argument("--log", required=True); r.add_argument("--rc", type=int, required=True); r.add_argument("--output", required=True)
    d = sub.add_parser("drift"); d.add_argument("--generated", required=True); d.add_argument("--committed", required=True)
    d.add_argument("--target", required=True); d.add_argument("--output", required=True)
    b = sub.add_parser("brief"); b.add_argument("--art", required=True); b.add_argument("--gate", action="store_true")
    a = ap.parse_args()
    return {"report": report, "drift": drift, "brief": brief}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
