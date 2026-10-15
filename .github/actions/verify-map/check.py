#!/usr/bin/env python3
"""Verification path map: validate verify.yml, resolve changed paths to rungs,
and check the PR body's verification table (issue #132).

Usage: check.py --changed changed.txt [--map verify.yml] [--schema verify.schema.json]
                [--high-risk-globs "g1 g2 ..."] [--pr-body body.md] [--require-table]
                [--output map.json]

Runs in a virtualenv with PyYAML and jsonschema. With no verify.yml the
HIGH_RISK_GLOBS fallback from verify-brief.yml applies: every matching changed
path is high risk with no rung (adoption needs no config on day one).
Outputs map.json for the verify-*.yml workflows: per changed file its risk,
rungs and tool, plus the lists of high-risk paths with no rung. With
--pr-body, the "## Verification" section must hold a non-empty table when
mapped paths changed; absent or empty fails with --require-table, warns
otherwise. Exit 1 on schema errors, on --require-table failures, and on a
changed high-risk path with no rung when --strict-high-risk.
"""

import argparse
import json
import os
import re
import sys

import yaml
from jsonschema import Draft202012Validator

HIGH_RISK_GLOBS = ("**/auth/** **/permissions/** **/billing/** **/payment*/** **/pricing/** **/crypto/** **/*secret* **/*token* "
                   "**/geometry/** **/geom/** **/crs/** **/projection*/** **/transform*/** **/tiles/** **/tile*/** **/index*/** "
                   "**/h3/** **/s2/** **/quadkey*")
EXT_TOOL = {".py": "python", ".go": "go", ".ts": "ts", ".tsx": "ts", ".js": "ts", ".jsx": "ts", ".mjs": "ts",
            ".dfy": "dafny", ".tla": "tla", ".als": "alloy", ".lean": "lean", ".rs": "rust"}


def glob_match(path, pattern):
    """Gitignore-style: ** spans directories; a pattern without a slash matches at any depth."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if pattern.startswith("**", i):
            out += ".*"; i += 2; continue
        c = pattern[i]
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    if re.fullmatch(out, path):
        return True
    if "/" not in pattern.rstrip("/"):
        return re.fullmatch("(?:.*/)?" + out, path) is not None
    if pattern.endswith("/**"):
        base = pattern[:-3]
        return path == base or path.startswith(base + "/")
    return False


def section(body, heading="## Verification"):
    lines, out, on = body.splitlines(), [], False
    for ln in lines:
        if ln.strip().lower().startswith(heading.lower()):
            on = True
            continue
        if on and re.match(r"^#{1,2}\s", ln):
            break
        if on:
            out.append(ln)
    return "\n".join(out)


def table_rows(text):
    rows = [ln for ln in text.splitlines() if ln.strip().startswith("|")]
    body = [r for r in rows[2:] if not re.match(r"^\|\s*-", r)]
    filled = []
    for r in body:
        cells = [c.strip() for c in r.strip().strip("|").split("|")]
        if len(cells) >= 2 and all(c and not re.fullmatch(r"<[^>]*>|tbd|\?|-", c.lower()) for c in cells[:2]):
            filled.append(cells)
    return filled


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed", required=True)
    ap.add_argument("--map", default="verify.yml")
    ap.add_argument("--schema", default="")
    ap.add_argument("--high-risk-globs", default="")
    ap.add_argument("--pr-body", default="")
    ap.add_argument("--require-table", action="store_true")
    ap.add_argument("--strict-high-risk", action="store_true")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    errors, warnings = [], []
    with open(args.changed, encoding="utf-8") as fh:
        changed = [ln.strip() for ln in fh if ln.strip()]
    entries, fallback = [], True
    high_risk = (args.high_risk_globs or HIGH_RISK_GLOBS).split()
    if os.path.exists(args.map):
        fallback = False
        try:
            with open(args.map, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh) or {}
        except yaml.YAMLError as e:
            errors.append(f"{args.map}: not valid YAML: {str(e).splitlines()[0]}")
            doc = {}
        if args.schema and os.path.exists(args.schema) and isinstance(doc, dict):
            with open(args.schema, encoding="utf-8") as fh:
                schema = json.load(fh)
            for err in sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: list(e.path)):
                where = "/".join(str(p) for p in err.absolute_path) or "(root)"
                errors.append(f"{args.map}: {where}: {err.message}")
        if isinstance(doc, dict):
            entries = [e for e in doc.get("paths", []) if isinstance(e, dict) and e.get("glob")]
            if doc.get("high_risk_globs"):
                high_risk = list(doc["high_risk_globs"])

    files = {}
    for f in changed:
        hits = [e for e in entries if glob_match(f, e["glob"])]
        if hits:
            e = max(hits, key=lambda e: len(e["glob"]))
            files[f] = {"glob": e["glob"], "risk": e.get("risk", "medium"), "rungs": list(e.get("rungs", [])),
                        "tool": e.get("tool") or EXT_TOOL.get(os.path.splitext(f)[1], None), "mapped": True}
        elif any(glob_match(f, g) for g in high_risk):
            files[f] = {"glob": None, "risk": "high", "rungs": [], "tool": EXT_TOOL.get(os.path.splitext(f)[1], None), "mapped": False}
        else:
            files[f] = {"glob": None, "risk": None, "rungs": [], "tool": EXT_TOOL.get(os.path.splitext(f)[1], None), "mapped": False}
    bare = sorted(f for f, m in files.items() if m["risk"] == "high" and not m["rungs"])
    mapped = sorted(f for f, m in files.items() if m["mapped"])
    for f in bare:
        (errors if args.strict_high_risk else warnings).append(f"{f}: high-risk path with no rung in {args.map if not fallback else 'the HIGH_RISK_GLOBS fallback (no verify.yml)'}")
    covers = []
    for e in entries:
        for cg in e.get("covers", []) or []:
            touched = [f for f in changed if glob_match(f, cg)]
            model_touched = [f for f in changed if glob_match(f, e["glob"])]
            if touched and not model_touched:
                covers.append(f"{', '.join(touched[:3])} changed but the model {e['glob']} did not")
    warnings += covers

    table = None
    if args.pr_body is not None and os.path.exists(args.pr_body or "/nonexistent"):
        with open(args.pr_body, encoding="utf-8") as fh:
            body = fh.read()
        rows = table_rows(section(body))
        table = len(rows)
        if mapped and not rows:
            (errors if args.require_table else warnings).append(
                f"{len(mapped)} mapped path(s) changed but the PR body's \"## Verification\" table is missing or empty: cite the contract, property, model or proof per acceptance criterion")

    for e in errors:
        print(f"::error title=verify-map::{e}")
    for w in warnings:
        print(f"::warning title=verify-map::{w}")
    lines = [f"## Verification map: {len(changed)} changed file(s), {len(mapped)} on mapped paths, {len(bare)} high-risk with no rung"
             + (" (no verify.yml: HIGH_RISK_GLOBS fallback)" if fallback else ""), ""]
    if files:
        lines += ["| File | Risk | Rungs | Tool |", "|---|---|---|---|"]
        lines += [f"| `{f}` | {m['risk'] or '-'} | {', '.join(m['rungs']) or ('**none**' if m['risk'] == 'high' else '-')} | {m['tool'] or '-'} |"
                  for f, m in sorted(files.items(), key=lambda kv: (kv[1]['risk'] != 'high', kv[0]))[:60]]
    if table is not None:
        lines += ["", f"PR body verification table: {table} filled row(s)."]
    if errors:
        lines += ["", "### Errors", ""] + [f"- {e}" for e in errors]
    if warnings:
        lines += ["", "### Advisory", ""] + [f"- {w}" for w in warnings]
    lines += ["", "Rungs and verdicts: docs/verification.md."]
    text = "\n".join(lines) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"mapped-count={len(mapped)}\nbare-high-risk-count={len(bare)}\nerror-count={len(errors)}\nfallback={str(fallback).lower()}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"fallback": fallback, "high_risk_globs": high_risk, "files": files, "mapped": mapped, "bare_high_risk": bare,
                       "table_rows": table, "errors": errors, "warnings": warnings,
                       "by_tool": {t: sorted(f for f, m in files.items() if m["mapped"] and m["tool"] == t) for t in sorted({m["tool"] for m in files.values() if m["mapped"] and m["tool"]})}},
                      fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
