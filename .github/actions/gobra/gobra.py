#!/usr/bin/env python3
"""Gobra output parser, brief and gate (issue #129).

Usage:
  gobra.py parse --log gobra-<pkg>.txt --package DIR --rc N --root PREFIX --output gobra-<pkg>.json
  gobra.py brief --art DIR [--fail-on-unsupported] [--gate]

parse: reads Gobra's log ("Error at: <file:line:col> message") and sorts each
error into a category:
  verification  Viper could not prove an obligation (postcondition, assertion,
                precondition of a call, permission, loop invariant);
  unsupported   Go that Gobra's parser or package loader does not accept
                (generics, an import it cannot resolve, a construct reported as
                not supported): restructure, or leave the package unmapped;
  typecheck     Gobra's type, ghost or property checks rejected the annotated
                program: an annotation mistake, or Go outside Gobra's subset.
Prints one ::error annotation per error (file prefixed with --root so it
points into the repository) and writes the package's JSON.
brief: merges gobra-*.json into gobra.json, writes verify-brief.md and
summary.json (tool "verify-gobra"; `gobra` is 0 when every package
verified, else 1) and gates: verification and typecheck errors block;
unsupported blocks with --fail-on-unsupported, else warns. Stdlib only.
"""

import argparse
import json
import os
import re
import sys

ERR = re.compile(r"Error at: <(?P<file>[^:>]+):(?P<line>\d+):(?P<col>\d+)> (?P<msg>.*)$")
UNSUPPORTED = re.compile(r"no viable alternative|mismatched input|extraneous input|token recognition error|missing '|"
                         r"Explicit qualifier could not be derived|No existing directory found for import path|"
                         r"not supported|unsupported|not yet implemented", re.I)
TYPECHECK = re.compile(r":error: |type error|ghost error|property error", re.I)


def category(msg):
    if UNSUPPORTED.search(msg):
        return "unsupported"
    if TYPECHECK.search(msg):
        return "typecheck"
    return "verification"


def parse(a):
    errors = []
    with open(a.log, encoding="utf-8", errors="ignore") as fh:
        for l in fh:
            m = ERR.search(l.rstrip())
            if not m:
                continue
            d = m.groupdict()
            msg = re.sub(r"^\S+:\d+:\d+:error: ", "", d["msg"]).strip()
            e = {"file": os.path.join(a.root, d["file"]) if a.root else d["file"], "line": int(d["line"]), "col": int(d["col"]),
                 "category": category(d["msg"]), "message": msg}
            errors.append(e)
            print(f"::error file={e['file']},line={e['line']},col={e['col']},title=gobra {e['category']}::{msg[:300]}")
    if a.rc != 0 and not errors:
        errors.append({"file": a.package, "line": 1, "col": 1, "category": "typecheck",
                       "message": f"Gobra exited {a.rc} without a located error (see the log)"})
    out = {"package": a.package, "rc": a.rc, "errors": errors}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"  {a.package}: rc={a.rc}, {len(errors)} error(s)")
    return 0


def brief(a):
    art = a.art
    pkgs = []
    for f in sorted(os.listdir(art)):
        if f.startswith("gobra-") and f.endswith(".json"):
            with open(os.path.join(art, f)) as fh:
                pkgs.append(json.load(fh))
    with open(f"{art}/gobra.json", "w") as fh:
        json.dump(pkgs, fh, indent=1)
    errs = [dict(e, package=p["package"]) for p in pkgs for e in p["errors"]]
    by = {c: [e for e in errs if e["category"] == c] for c in ("verification", "unsupported", "typecheck")}
    M = ["## Verification brief (Gobra)", ""]
    if not pkgs:
        M += ["No changed package carries the `gobra` rung.", ""]
    else:
        M += ["| Package | Result |", "|---|---|"]
        M += [f"| `{p['package']}` | " + ("verified" if p["rc"] == 0 and not p["errors"] else
                                       "**" + ", ".join(f"{sum(1 for e in p['errors'] if e['category'] == c)} {c}"
                                                       for c in by if any(e['category'] == c for e in p['errors'])) + "**") + " |"
              for p in pkgs]
        M += [""]
        if errs:
            M += ["| Where | Category | Message |", "|---|---|---|"]
            M += [f"| `{e['file']}:{e['line']}` | {e['category']} | {e['message'][:140]} |" for e in errs[:25]]
            M += [""]
        if by["unsupported"]:
            M += ["> **unsupported**: Gobra's parser or loader does not accept this Go (generics, an import it cannot "
                  "resolve, reflection). Move the verified core into a package that avoids it, or drop the `gobra` rung "
                  "for the path. Nothing in that package was verified.", ""]
        if by["typecheck"]:
            M += ["> **typecheck**: Gobra rejected the annotated program before verifying it: check the `//@` "
                  "annotations (ghost code may only call `pure` functions) or the construct named.", ""]
    M += ["> Gobra proofs cover the annotated package only, under Gobra's model of Go; calls into unannotated "
          "packages are trusted.", "", "Rungs and verdicts: docs/verification.md."]
    with open(f"{art}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")
    fail, warn = [], []
    if by["verification"]:
        fail.append(f"{len(by['verification'])} Gobra verification error(s): an annotated contract does not hold")
    if by["typecheck"]:
        fail.append(f"{len(by['typecheck'])} Gobra type-check error(s) in annotated packages")
    if by["unsupported"]:
        (fail if a.fail_on_unsupported else warn).append(f"{len(by['unsupported'])} unsupported construct(s): those packages were not verified")
    summary = {"gobra": None if not pkgs else (0 if not errs and all(p["rc"] == 0 for p in pkgs) else 1),
               "counterexamples": 0, "unverified": len(by["unsupported"]), "bare_high_risk": 0, "strict": True,
               "tool": "verify-gobra", "packages": len(pkgs), "gate": {"fail": fail, "warn": warn}}
    with open(f"{art}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"gobra={'' if summary['gobra'] is None else summary['gobra']}\npackages={len(pkgs)}\n"
                     f"verification-errors={len(by['verification'])}\nunsupported={len(by['unsupported'])}\nblocking={len(fail)}\n")
    for w in warn:
        print(f"  warn: {w}")
        print(f"::warning title=verify-gobra::{w}")
    for f in fail:
        print(f"  FAIL: {f}")
        print(f"::error title=verify-gobra::{f}")
    print(f"\n{len(fail)} blocking, {len(warn)} advisory")
    return 1 if (a.gate and fail) else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parse")
    p.add_argument("--log", required=True); p.add_argument("--package", required=True); p.add_argument("--rc", type=int, required=True)
    p.add_argument("--root", default=""); p.add_argument("--output", required=True)
    b = sub.add_parser("brief")
    b.add_argument("--art", required=True); b.add_argument("--fail-on-unsupported", action="store_true"); b.add_argument("--gate", action="store_true")
    a = ap.parse_args()
    return {"parse": parse, "brief": brief}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
