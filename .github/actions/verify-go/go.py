#!/usr/bin/env python3
"""Go census (verify-brief.yml step "Go", issue #126).

Usage: go.py --art DIR [--map verify-map.json] [--high-risk-globs "g1 g2"]

Reads from DIR: status/{vet,staticcheck,nilaway,errcheck} exit codes, the
matching go-*.txt outputs, fuzzcover.json (fuzzcover.go), fuzz-run.txt (one
"<pkg> <target>" per target run), crashers.txt (new files under testdata/fuzz
after the per-PR fuzz), changed.txt and changed-go.txt (paths relative to the
module root). Writes DIR/go.json with the brief's fields (vet, staticcheck,
nilaway, vet_lines, staticcheck_lines, nilaway_lines, fuzz_targets, crashers,
property_files) plus errcheck, the mapped exported functions no Fuzz* target
calls, high-risk packages with no rapid/quick property, corpus-hygiene
violations (a committed testdata/fuzz/<Name>/ entry whose Name is not a Fuzz*
target of that package, or whose file is not a `go test fuzz v1` corpus file)
and a reproduction command per crasher. Stdlib only.
"""

import argparse
import fnmatch
import json
import os
import re
import sys

HIGH_RISK_GLOBS = ("**/auth/** **/permissions/** **/billing/** **/payment*/** **/pricing/** **/crypto/** **/*secret* **/*token* "
                   "**/geometry/** **/geom/** **/crs/** **/projection*/** **/transform*/** **/tiles/** **/tile*/** **/index*/** "
                   "**/h3/** **/s2/** **/quadkey*")
CORPUS_RE = re.compile(r"^(?:(?P<pkg>.+)/)?testdata/fuzz/(?P<target>[^/]+)/(?P<file>[^/]+)$")


def is_high_risk(path, globs):
    return any(fnmatch.fnmatch(path, g) or (g.startswith("**/") and fnmatch.fnmatch(path, g[3:]))
               for g in globs)


def read_lines(p):
    try:
        with open(p, encoding="utf-8", errors="ignore") as fh:
            return [l.strip() for l in fh if l.strip()]
    except OSError:
        return []


def status(art, name):
    try:
        with open(f"{art}/status/{name}") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def count(p):
    return sum(1 for l in read_lines(p) if not l.startswith("#"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--map", default="")
    ap.add_argument("--high-risk-globs", default="")
    args = ap.parse_args()
    art = args.art
    globs = (args.high_risk_globs or HIGH_RISK_GLOBS).split()
    map_files = {}
    if args.map and os.path.isfile(args.map):
        with open(args.map, encoding="utf-8") as fh:
            m = json.load(fh)
        map_files = m.get("files", {})
        if m.get("high_risk_globs"):
            globs = list(m["high_risk_globs"])

    def entry(f):
        return map_files.get(f) or next((m for k, m in map_files.items() if k.endswith("/" + f)), None)

    try:
        with open(f"{art}/fuzzcover.json", encoding="utf-8") as fh:
            cover = json.load(fh)
    except (OSError, ValueError):
        cover = []
    targets_by_pkg = {p["dir"]: set(p["fuzz_targets"]) for p in cover}
    sources = [f for f in read_lines(f"{art}/changed-go.txt") if not f.endswith("_test.go")]
    hr_pkgs = sorted({os.path.dirname(f) or "." for f in sources
                      if (entry(f) or {}).get("risk") == "high" or (not entry(f) and is_high_risk(f, globs))})
    props = {p["dir"]: p["property_files"] for p in cover}
    without_property = [d for d in hr_pkgs if not props.get(d)]
    uncovered = [{"dir": p["dir"], "name": fn["name"], "file": fn["file"], "line": fn["line"]}
                 for p in cover for fn in p["functions"] if fn["name"] in p["uncovered"]]

    hygiene = []
    for f in read_lines(f"{art}/changed.txt"):
        m = CORPUS_RE.match(f)
        if not m:
            continue
        pkg = m.group("pkg") or "."
        if m.group("target") not in targets_by_pkg.get(pkg, set()):
            hygiene.append(f"{f}: no Fuzz target {m.group('target')} in package {pkg}")
        elif os.path.isfile(f):
            with open(f, encoding="utf-8", errors="ignore") as fh:
                head = fh.readline().strip()
            if head != "go test fuzz v1":
                hygiene.append(f"{f}: not a go test fuzz v1 corpus file")

    crashers = []
    for f in read_lines(f"{art}/crashers.txt"):
        m = CORPUS_RE.match(f)
        pkg, target, name = (m.group("pkg") or ".", m.group("target"), m.group("file")) if m else (".", "?", os.path.basename(f))
        crashers.append({"file": f, "package": pkg, "target": target,
                         "reproduce": f"go test -run='^{target}/{name}$' ./{pkg if pkg != '.' else ''}".rstrip("/")})
    run = read_lines(f"{art}/fuzz-run.txt")
    go = {"vet": status(art, "vet"), "staticcheck": status(art, "staticcheck"), "nilaway": status(art, "nilaway"),
          "errcheck": status(art, "errcheck"),
          "vet_lines": count(f"{art}/go-vet.txt"), "staticcheck_lines": count(f"{art}/go-staticcheck.txt"),
          "nilaway_lines": count(f"{art}/go-nilaway.txt"), "errcheck_lines": count(f"{art}/go-errcheck.txt"),
          "fuzz_targets": len(run), "crashers": [c["file"] for c in crashers], "crasher_details": crashers,
          "property_files": sum(len(v) for v in props.values()),
          "packages": len(cover), "uncovered": uncovered, "high_risk_packages": hr_pkgs,
          "high_risk_without_property": without_property, "hygiene": hygiene}
    with open(f"{art}/go.json", "w") as fh:
        json.dump(go, fh, indent=1)
    print(f"  vet={go['vet']} staticcheck={go['staticcheck']} nilaway={go['nilaway']} errcheck={go['errcheck']}; "
          f"{go['fuzz_targets']} fuzz target(s), {len(crashers)} crasher(s), {go['property_files']} property test file(s); "
          f"{len(uncovered)} mapped function(s) without a fuzz target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
