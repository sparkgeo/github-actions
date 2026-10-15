#!/usr/bin/env python3
"""Contract census (verify-brief.yml step "Contract census", issue #125).

Usage: census.py --changed changed-py.txt [--map verify-map.json] [--high-risk-globs "g1 g2"] --output census.json

Which changed public functions state a postcondition at all. A function with no
contract gives CrossHair nothing to refute, so this comes first. A function is
contracted when it carries an icontract or deal decorator, a PEP 316 docstring
(pre:/post:/inv: lines) or a trailing assert. High risk comes from
verify-map.json when present (risk == "high"), else from the HIGH_RISK_GLOBS
fallback. Calls into GEOS, PROJ, NumPy, GDAL, rasterio or fiona are reported as
an "opaque boundary": CrossHair cannot see inside a C extension, so a "Not
confirmed" on such a function is a boundary, not a failure. Stdlib only.
"""

import argparse
import ast
import fnmatch
import json
import os
import sys

HIGH_RISK_GLOBS = ("**/auth/** **/permissions/** **/billing/** **/payment*/** **/pricing/** **/crypto/** **/*secret* **/*token* "
                   "**/geometry/** **/geom/** **/crs/** **/projection*/** **/transform*/** **/tiles/** **/tile*/** **/index*/** "
                   "**/h3/** **/s2/** **/quadkey*")
CONTRACT_DECOS = {"require", "ensure", "invariant", "pre", "post", "inv", "pure",
                  "has", "raises", "safe"}          # icontract + deal spellings
# C-extension packages CrossHair cannot trace into (the brief's "opaque boundary")
OPAQUE_MODULES = {"shapely", "pyproj", "numpy", "np", "osgeo", "gdal", "ogr", "osr", "rasterio", "fiona", "geos", "rtree", "scipy"}


def is_high_risk(path, globs):
    return any(fnmatch.fnmatch(path, g) or (g.startswith("**/") and fnmatch.fnmatch(path, g[3:]))
               for g in globs)


def deco_name(d):
    d = d.func if isinstance(d, ast.Call) else d
    return d.attr if isinstance(d, ast.Attribute) else getattr(d, "id", "")


def has_pep316(doc):
    return bool(doc) and any(l.strip().startswith(("pre:", "post:", "inv:")) for l in doc.splitlines())


def opaque_calls(tree, fn):
    """Names of C-extension modules the function calls, resolved through imports."""
    alias = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                root = a.name.split(".")[0]
                alias[a.asname or root] = root
        elif isinstance(n, ast.ImportFrom) and n.module:
            root = n.module.split(".")[0]
            for a in n.names:
                alias[a.asname or a.name] = root
    hits = set()
    for n in ast.walk(fn):
        if not isinstance(n, ast.Call):
            continue
        f = n.func
        while isinstance(f, ast.Attribute):
            f = f.value
        name = getattr(f, "id", "")
        root = alias.get(name, name)
        if root in OPAQUE_MODULES:
            hits.add(root)
    return sorted(hits)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed", required=True)
    ap.add_argument("--map", default="")
    ap.add_argument("--high-risk-globs", default="")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    globs = (args.high_risk_globs or HIGH_RISK_GLOBS).split()
    map_files = {}
    if args.map and os.path.isfile(args.map):
        with open(args.map, encoding="utf-8") as fh:
            m = json.load(fh)
        map_files = m.get("files", {})
        if m.get("high_risk_globs"):
            globs = list(m["high_risk_globs"])
    rows = []
    with open(args.changed, encoding="utf-8") as fh:
        changed = [l.strip() for l in fh if l.strip()]
    for f in changed:
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                tree = ast.parse(fh.read())
        except (SyntaxError, ValueError):
            continue
        # map.json keys are repository-relative; f may be relative to working-directory
        entry = map_files.get(f) or next((m for k, m in map_files.items() if k.endswith("/" + f)), None)
        hr = entry["risk"] == "high" if entry else is_high_risk(f, globs)
        for n in ast.walk(tree):
            if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if n.name.startswith("_"):
                continue
            decos = {deco_name(d) for d in n.decorator_list}
            kinds = sorted(decos & CONTRACT_DECOS)
            if has_pep316(ast.get_docstring(n)):
                kinds.append("PEP316")
            # a bare `assert` on the way out is the poor man's postcondition
            if any(isinstance(b, ast.Assert) for b in n.body[-2:]):
                kinds.append("assert")
            rows.append({"file": f, "line": n.lineno, "name": n.name,
                         "contracts": kinds, "high_risk": hr, "opaque": opaque_calls(tree, n)})
    with open(args.output, "w") as fh:
        json.dump(rows, fh, indent=1)
    c = sum(1 for r in rows if r["contracts"])
    h = sum(1 for r in rows if r["high_risk"] and not r["contracts"])
    o = sum(1 for r in rows if r["opaque"])
    print(f"  {len(rows)} public function(s) changed, {c} contracted, {h} uncontracted on high-risk paths, {o} crossing an opaque boundary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
