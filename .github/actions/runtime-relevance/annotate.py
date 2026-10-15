#!/usr/bin/env python3
"""Mark SARIF findings with runtime relevance from runtime-relevance.json.

Usage: annotate.py --sarif FILE --export FILE --output FILE [--image DIGEST]

Each result's CVE comes from its ruleId (Trivy: CVE-…; Grype:
CVE-…-<package>) and its package from "Package: <name>" in the message text
(Trivy) or the ruleId suffix (Grype). Matching export entries (same image
digest when --image is given) set properties["runtime-relevant"]:
true when any entry says the package is loaded, false when every entry says
it is not, "unknown" otherwise; false also adds the tag
"runtime:not-loaded". Results with no export entry are left alone.
Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import re

CVE = re.compile(r"(CVE-\d{4}-\d+)(?:-(.+))?$")
PKG = re.compile(r"Package:\s*(\S+)")


def verdict(values):
    if any(v is True for v in values):
        return True
    if values and all(v is False for v in values):
        return False
    return "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sarif", required=True)
    ap.add_argument("--export", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--image", default="")
    a = ap.parse_args()

    with open(a.export, encoding="utf-8") as f:
        export = json.load(f)
    index = {}
    for e in export.get("entries") or []:
        if a.image and e.get("image") != a.image:
            continue
        index.setdefault((e.get("cve"), e.get("package")), []).append(e.get("relevant"))
        index.setdefault((e.get("cve"), None), []).append(e.get("relevant"))

    with open(a.sarif, encoding="utf-8") as f:
        sarif = json.load(f)
    counts = {True: 0, False: 0, "unknown": 0}
    for run in sarif.get("runs") or []:
        for res in run.get("results") or []:
            m = CVE.match(res.get("ruleId", ""))
            if not m:
                continue
            pm = PKG.search((res.get("message") or {}).get("text", ""))
            pkg = pm.group(1) if pm else m.group(2)
            values = index.get((m.group(1), pkg)) if pkg else None
            if values is None:
                values = index.get((m.group(1), None))
            if not values:
                continue
            v = verdict(values)
            props = res.setdefault("properties", {})
            props["runtime-relevant"] = v
            props["runtime-relevance-generated-at"] = export.get("generated_at", "")
            if v is False:
                props["tags"] = sorted(set(props.get("tags", [])) | {"runtime:not-loaded"})
            counts[v] += 1

    with open(a.output, "w", encoding="utf-8") as f:
        json.dump(sarif, f, indent=1)
    print(f"runtime-relevance: {counts[True]} loaded, {counts[False]} not loaded, {counts['unknown']} unknown")
    return counts


if __name__ == "__main__":
    c = main()
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write(f"not-loaded={c[False]}\n")
