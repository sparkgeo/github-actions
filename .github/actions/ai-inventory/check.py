#!/usr/bin/env python3
"""AI agent and MCP configuration inventory check (issue #102).

Usage: check.py --root DIR --inventory docs/ai-agents.md --patterns FILE
                [--extra-patterns GLOB,GLOB] [--exclude DIR,DIR] [--output report.json]

Every file under --root that matches a pattern must be covered by one row
of the inventory table whose "Config path" glob matches it, and every row
must carry the registry fields SecOps plan Step 26 asks for: owner, class,
risk tier, lifecycle state and kill switch. A row in lifecycle state
"retired" must match no file. A row whose path matches no file is a warning
(stale), not an error. Exit 1 on any error. Standard library only; run with
python3 -I.

Inventory format: the first Markdown table in the file whose header row
(the line above a |---| separator) has a "Config path" column. Cells may hold several globs separated by "<br>", ";"
or ", ". Backticks are ignored.
"""

import argparse
import glob
import json
import os
import re
import sys

REQUIRED_COLUMNS = ["name", "config path", "provider", "class", "risk tier", "lifecycle state", "credential",
                    "permitted tools and data classes", "write access to production", "human approval required",
                    "owner", "kill switch", "dpa on file"]
MUST_BE_SET = ["owner", "class", "risk tier", "kill switch", "lifecycle state"]
ENUMS = {
    "class": {"on-behalf-of", "autonomous", "orchestrator", "guardian"},
    "risk tier": {"low", "medium", "high"},
    "lifecycle state": {"proposed", "active", "suspended", "retired"},
    "write access to production": {"yes", "no"},
    "human approval required": {"yes", "no"},
}
ROW_TEMPLATE = ("| <name> | `<config path>` | <provider> | on-behalf-of \\| autonomous \\| orchestrator \\| guardian | "
                "low \\| medium \\| high | proposed \\| active \\| suspended \\| retired | <GitHub App / OIDC / API key: SECRET_NAME> | "
                "<tools; data classes> | yes \\| no | yes \\| no | <team-x or user@sparkgeo.com> | "
                "<which key to revoke, which account to disable, who may; last drilled YYYY-MM-DD> | yes \\| no \\| n/a |")


def glob_to_regex(pattern):
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if pattern.startswith("**", i):
            out += ".*"; i += 2; continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def load_patterns(path, extra):
    pats = []
    if path and os.path.exists(path):
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line:
                pats.append(line)
    pats += [p.strip() for p in (extra or "").split(",") if p.strip()]
    return pats


def matched_files(root, patterns, excludes):
    found = set()
    for p in patterns:
        for hit in glob.glob(p, root_dir=root, recursive=True, include_hidden=True):
            full = os.path.join(root, hit)
            if not os.path.isfile(full):
                continue
            rel = hit.replace(os.sep, "/")
            if any(rel == e or rel.startswith(e.rstrip("/") + "/") or f"/{e}/" in f"/{rel}/" for e in excludes):
                continue
            found.add(rel)
    return sorted(found)


def parse_inventory(path):
    """Return (rows, errors). rows: list of dicts keyed by normalised header."""
    if not os.path.exists(path):
        return [], [f"inventory {path} does not exist"]
    lines = open(path).read().split("\n")
    for i, line in enumerate(lines):
        is_header = (line.strip().startswith("|") and "config path" in line.lower()
                     and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}", lines[i + 1]))
        if is_header:
            headers = [h.strip().strip("*").strip().lower() for h in line.strip().strip("|").split("|")]
            missing = [c for c in REQUIRED_COLUMNS if c not in headers]
            if missing:
                return [], [f"inventory table is missing the column(s): {', '.join(missing)}"]
            rows = []
            for j in range(i + 2, len(lines)):
                row = lines[j].strip()
                if not row.startswith("|"):
                    break
                cells = [c.strip() for c in row.strip("|").split("|")]
                if len(cells) < len(headers):
                    cells += [""] * (len(headers) - len(cells))
                rows.append({"_line": j + 1, **dict(zip(headers, cells))})
            return rows, []
    return [], [f"{path} has no table with a \"Config path\" column"]


def cell_globs(cell):
    cell = cell.replace("`", "")
    parts = re.split(r"<br\s*/?>|;|,\s", cell)
    return [p.strip() for p in parts if p.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--inventory", default="docs/ai-agents.md")
    ap.add_argument("--patterns", required=True)
    ap.add_argument("--extra-patterns", default="")
    ap.add_argument("--exclude", default=".git,node_modules,.sparkgeo-github-actions,.sparkgeo-policies")
    ap.add_argument("--output")
    args = ap.parse_args()

    inv_path = os.path.join(args.root, args.inventory)
    rows, errors = parse_inventory(inv_path)
    warnings = []
    patterns = load_patterns(args.patterns, args.extra_patterns)
    excludes = [e.strip() for e in args.exclude.split(",") if e.strip()]
    files = matched_files(args.root, patterns, excludes)

    compiled = []
    for r in rows:
        name = r.get("name") or f"row at line {r['_line']}"
        for col in MUST_BE_SET:
            if not r.get(col) or r[col].lower() in ("", "-", "tbd", "?"):
                errors.append(f"{args.inventory}:{r['_line']}: {name}: \"{col}\" is empty")
        for col, allowed in ENUMS.items():
            val = (r.get(col) or "").strip().lower()
            if val and val not in allowed:
                errors.append(f"{args.inventory}:{r['_line']}: {name}: \"{col}\" is \"{r[col]}\", expected one of {', '.join(sorted(allowed))}")
        r["_globs"] = [(g, glob_to_regex(g)) for g in cell_globs(r.get("config path", ""))]
        if not r["_globs"]:
            errors.append(f"{args.inventory}:{r['_line']}: {name}: \"config path\" is empty")
        compiled.append(r)

    coverage = {}
    for f in files:
        owners = [r for r in compiled if any(rx.match(f) for _, rx in r["_globs"])]
        active = [r for r in owners if (r.get("lifecycle state") or "").lower() != "retired"]
        retired = [r for r in owners if (r.get("lifecycle state") or "").lower() == "retired"]
        if retired and not active:
            errors.append(f"{f}: covered only by a retired row ({', '.join(r.get('name', '') for r in retired)}); remove the file or re-activate the row")
        elif not active:
            errors.append(f"{f}: no inventory row covers it; add a row to {args.inventory}")
        coverage[f] = [r.get("name", "") for r in active]
    for r in compiled:
        if (r.get("lifecycle state") or "").lower() == "retired":
            continue
        if not any(rx.match(f) for f in files for _, rx in r["_globs"]):
            warnings.append(f"{args.inventory}:{r['_line']}: {r.get('name', '')}: config path matches no file (stale row?)")

    for e in errors:
        loc = ""
        m = re.match(r"^([^:]+):(\d+): ", e)
        if m:
            loc = f"file={m.group(1)},line={m.group(2)},"
        print(f"::error {loc}title=ai-inventory::{e}")
    for w in warnings:
        print(f"::warning title=ai-inventory::{w}")

    summary = [f"## AI agent inventory: {len(files)} configuration file(s), {len(compiled)} row(s), {len(errors)} error(s), {len(warnings)} warning(s)", ""]
    if files:
        summary += ["| File | Covered by |", "|---|---|"] + [f"| `{f}` | {', '.join(coverage[f]) or '**none**'} |" for f in files]
    if errors:
        summary += ["", "### Errors", ""] + [f"- {e}" for e in errors]
        summary += ["", "Row template for a missing entry:", "", "```", ROW_TEMPLATE, "```"]
    if warnings:
        summary += ["", "### Warnings", ""] + [f"- {w}" for w in warnings]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"file-count={len(files)}\nrow-count={len(compiled)}\nerror-count={len(errors)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"files": coverage, "rows": [{k: v for k, v in r.items() if not k.startswith('_')} for r in compiled],
                       "errors": errors, "warnings": warnings}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
