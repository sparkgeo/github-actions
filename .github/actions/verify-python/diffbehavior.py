#!/usr/bin/env python3
"""Semantic diff against base (verify-brief.yml step "Semantic diff against
base", issue #125).

Usage: diffbehavior.py --changed changed-py.txt --base <git ref> --crosshair <bin>
                       [--per-condition-timeout 45] [--basecopy DIR] --output diffbehavior.json

"Does the new implementation agree with the old one on every input?" Answered
per changed public function that also exists on the base branch, by importing
the base copy under a throwaway module name. Modules with relative imports
cannot be loaded that way and are skipped, not guessed. Functions wrapped by
icontract or deal decorators may come back "unsupported": the wrapper confuses
the symbolic tracer. Verdicts: differs, agrees (within budget), unsupported.
"""

import argparse
import ast
import json
import os
import re
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--crosshair", default="crosshair")
    ap.add_argument("--per-condition-timeout", default="45")
    ap.add_argument("--basecopy", default="/tmp/basecopy")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    os.makedirs(args.basecopy, exist_ok=True)
    out = []
    with open(args.changed, encoding="utf-8") as fh:
        changed = [l.strip() for l in fh if l.strip()]
    for f in changed:
        if not os.path.isfile(f):
            continue
        r = subprocess.run(["git", "show", f"{args.base}:{f}"], capture_output=True, text=True)
        if r.returncode != 0:
            continue                       # new file: nothing to compare
        if re.search(r"^\s*from\s+\.", r.stdout, re.M):
            continue                       # relative imports: skip
        alias = "base_" + re.sub(r"\W", "_", f[:-3])
        with open(os.path.join(args.basecopy, alias + ".py"), "w", encoding="utf-8") as fh:
            fh.write(r.stdout)
        try:
            old = {n.name for n in ast.walk(ast.parse(r.stdout)) if isinstance(n, ast.FunctionDef)}
            with open(f, encoding="utf-8", errors="ignore") as fh:
                new = {n.name for n in ast.walk(ast.parse(fh.read())) if isinstance(n, ast.FunctionDef)}
        except SyntaxError:
            continue
        mod = f[:-3].replace("/", ".")
        for fn in sorted((old & new) - {n for n in old if n.startswith("_")}):
            p = subprocess.run([args.crosshair, "diffbehavior", f"{alias}.{fn}", f"{mod}.{fn}",
                                "--per_condition_timeout", str(args.per_condition_timeout)],
                               capture_output=True, text=True,
                               env={**os.environ, "PYTHONPATH": args.basecopy + ":" + os.environ.get("PYTHONPATH", ".")})
            txt = (p.stdout + p.stderr).strip()
            verdict = ("differs" if "Given" in txt or p.returncode == 1 else
                       "agrees (within budget)" if p.returncode == 0 else "unsupported")
            out.append({"file": f, "function": fn, "verdict": verdict, "detail": txt[:300]})
    with open(args.output, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"  {len(out)} function(s) compared, {sum(1 for o in out if o['verdict'] == 'differs')} differ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
