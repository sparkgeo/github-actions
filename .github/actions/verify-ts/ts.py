#!/usr/bin/env python3
"""TypeScript / JavaScript census (verify-brief.yml step "TypeScript /
JavaScript", issue #125's sibling #127).

Usage: ts.py --art DIR --tsc-rc N [--map verify-map.json] [--high-risk-globs "g1 g2"]

Reads DIR/changed-ts.txt and DIR/tsc.txt (paths relative to the project) and
writes DIR/ts.json with the brief's fields: tsc, tsc_errors_all,
tsc_errors_changed, changed, test_files, property_files, schema_files. Errors
in changed files vs pre-existing: only the former is this PR's problem. Adds
`high_risk` (changed non-test files on high-risk paths, from verify-map.json or
the HIGH_RISK_GLOBS fallback), `mapped` (changed non-test files on mapped
paths) and `high_risk_without_property` (of those high-risk files, the ones no
test file in the project exercises with fast-check). Stdlib only.
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

HIGH_RISK_GLOBS = ("**/auth/** **/permissions/** **/billing/** **/payment*/** **/pricing/** **/crypto/** **/*secret* **/*token* "
                   "**/geometry/** **/geom/** **/crs/** **/projection*/** **/transform*/** **/tiles/** **/tile*/** **/index*/** "
                   "**/h3/** **/s2/** **/quadkey*")
TEST_RE = re.compile(r"\.(test|spec)\.[tj]sx?$")
FC_RE = re.compile(r"fc\.(assert|property|asyncProperty|check)")


def is_high_risk(path, globs):
    return any(fnmatch.fnmatch(path, g) or (g.startswith("**/") and fnmatch.fnmatch(path, g[3:]))
               for g in globs)


def read(p):
    try:
        with open(p, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--tsc-rc", type=int, required=True, help="-1: no tsconfig.json")
    ap.add_argument("--map", default="")
    ap.add_argument("--high-risk-globs", default="")
    args = ap.parse_args()
    art, tsc = args.art, args.tsc_rc
    globs = (args.high_risk_globs or HIGH_RISK_GLOBS).split()
    map_files, fallback = {}, True
    if args.map and os.path.isfile(args.map):
        with open(args.map, encoding="utf-8") as fh:
            m = json.load(fh)
        map_files, fallback = m.get("files", {}), bool(m.get("fallback", True))
        if m.get("high_risk_globs"):
            globs = list(m["high_risk_globs"])

    def entry(f):
        # map.json keys are repository-relative; f is relative to the project
        return map_files.get(f) or next((m for k, m in map_files.items() if k.endswith("/" + f)), None)

    changed = [l.strip() for l in read(f"{art}/changed-ts.txt").splitlines() if l.strip()]
    changed_set = set(changed)
    errs_all, errs_changed = 0, 0
    for l in read(f"{art}/tsc.txt").splitlines():
        m = re.match(r"^(.+?)\(\d+,\d+\): error TS\d+", l)
        if m:
            errs_all += 1
            if m.group(1) in changed_set:
                errs_changed += 1
    tests = [f for f in changed if TEST_RE.search(f)]
    prop = [f for f in tests if os.path.isfile(f) and FC_RE.search(read(f))]
    sources = [f for f in changed if f not in tests and os.path.isfile(f)]
    schema = [f for f in sources if re.search(r"\b(z\.object|z\.\w+\(|v\.object|valibot)", read(f))]
    high_risk = [f for f in sources if (entry(f) or {}).get("risk") == "high" or (not entry(f) and is_high_risk(f, globs))]
    mapped = [f for f in sources if (entry(f) or {}).get("mapped")]
    if fallback and not mapped:
        mapped = list(high_risk)
    # which project test files use fast-check, and which modules they import
    listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], capture_output=True, text=True).stdout.split()
    fc_tests = [read(t) for t in listed if TEST_RE.search(t) and "node_modules/" not in t]
    fc_tests = [t for t in fc_tests if FC_RE.search(t)]

    def has_property(f):
        stem = os.path.splitext(os.path.basename(f))[0]
        imp = re.compile(r"""(?:from|import\(|require\()\s*['"][^'"]*/""" + re.escape(stem) + r"""(?:\.[mc]?[jt]sx?)?['"]""")
        return any(imp.search(t) for t in fc_tests)

    without = [f for f in high_risk if not has_property(f)]
    with open(f"{art}/ts.json", "w") as fh:
        json.dump({"tsc": tsc, "tsc_errors_all": errs_all, "tsc_errors_changed": errs_changed,
                   "changed": len(changed), "test_files": len(tests), "property_files": prop, "schema_files": len(schema),
                   "high_risk": high_risk, "mapped": mapped, "high_risk_without_property": without},
                  fh, indent=1)
    print(f"  tsc rc={tsc}: {errs_changed} error(s) in changed files ({errs_all} total); "
          f"{len(prop)}/{len(tests)} changed test file(s) use fast-check; {len(schema)} changed file(s) declare schemas; "
          f"{len(without)} high-risk file(s) with no fast-check property")
    return 0


if __name__ == "__main__":
    sys.exit(main())
