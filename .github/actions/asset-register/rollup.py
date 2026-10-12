#!/usr/bin/env python3
"""Org-wide asset register from per-repository inventories (issue #116).

Usage: rollup.py --inventories DIR --output-dir DIR [--teams policies/tags/teams.yml]
                 [--stale-days 7] [--svg] [--now ISO8601]

--inventories holds one subdirectory per repository with the inventory.json
published by asset-inventory.yml (checksums are verified by the caller).
Writes assets.json, owners.md, unowned.md, data-classes.md, register.dot
(and register.svg with --svg when dot is installed), summary.md and
SHA256SUMS. An asset is unowned when it has tag violations or its owner is a
team-* value missing from the team list (an empty list accepts any team).
Exit 0 always; the tracking issue is the workflow's job.
Standard library only; run with python3 -I.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

TITLE = "asset-register"
TEAMS_PATH = "policies/tags/teams.yml"


def load_inventory_module():
    """Grouping and DOT renderer from the sibling asset-inventory composite."""
    sys.dont_write_bytecode = True  # keep __pycache__ out of the checkout
    path = Path(__file__).resolve().parent.parent / "asset-inventory" / "inventory.py"
    spec = importlib.util.spec_from_file_location("inventory", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def warn(msg):
    print(f"::warning title={TITLE}::{msg}")


def parse_ts(value):
    try:
        return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def load_teams(path):
    """Names under `teams:` in a flat YAML list; None when no file was given."""
    if not path:
        return None
    teams, in_list = [], False
    for line in Path(path).read_text().splitlines():
        stripped = line.split("#", 1)[0].rstrip()
        if not stripped:
            continue
        if re.match(r"^teams:\s*\[\s*\]\s*$", stripped):
            return []
        if re.match(r"^teams:\s*$", stripped):
            in_list = True
            continue
        m = re.match(r"^\s+-\s*['\"]?([^'\"]+?)['\"]?\s*$", stripped)
        if in_list and m:
            teams.append(m.group(1))
        elif in_list and not stripped.startswith(" "):
            in_list = False
    return teams


def load_inventories(root):
    for path in sorted(Path(root).glob("*/inventory.json")):
        rel = path.relative_to(root).as_posix()
        try:
            with open(path) as f:
                inv = json.load(f)
            inv["resources"]
            inv["repo"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            warn(f"{rel} unreadable, skipped: {exc}")
            continue
        yield inv


def unowned_reason(asset, teams):
    if asset["tag_violations"]:
        return "missing " + ", ".join(asset["tag_violations"])
    owner = asset["tags"].get("owner", "")
    if teams and owner.startswith("team-") and owner not in teams:
        return f"owner {owner} is not in {TEAMS_PATH}"
    return None


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return out


def write(path, text):
    with open(path, "w") as f:
        f.write(text if text.endswith("\n") else text + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inventories", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--teams")
    ap.add_argument("--stale-days", type=int, default=7)
    ap.add_argument("--svg", action="store_true")
    ap.add_argument("--now")
    args = ap.parse_args()

    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc).replace(microsecond=0)
    teams = load_teams(args.teams)
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    repos, assets = [], []
    for inv in load_inventories(args.inventories):
        generated = parse_ts(inv.get("generated_at"))
        age = (now - generated).days if generated else None
        stale = age is None or age > args.stale_days
        if stale:
            warn(f"{inv['repo']} inventory is {age if age is not None else 'an unknown number of'} days old (stale after {args.stale_days})")
        repos.append({"repo": inv["repo"], "generated_at": inv.get("generated_at"), "stack_kind": inv.get("stack_kind"),
                      "resources": len(inv["resources"]), "violations": sum(1 for r in inv["resources"] if r.get("tag_violations")),
                      "age_days": age, "stale": stale})
        for r in inv["resources"]:
            a = dict(r, repo=inv["repo"])
            a["unowned_reason"] = unowned_reason(a, teams)
            assets.append(a)
    if not repos:
        warn(f"no inventories found under {args.inventories}")
    repos.sort(key=lambda r: r["repo"])
    assets.sort(key=lambda a: (a["repo"], a["stack"], a["id"]))
    unowned = [a for a in assets if a["unowned_reason"]]
    stale_repos = [r for r in repos if r["stale"]]

    register = {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "stale_days": args.stale_days,
        "teams_file": args.teams, "repos": repos,
        "counts": {"repos": len(repos), "assets": len(assets), "unowned": len(unowned), "stale_repos": len(stale_repos)},
        "assets": assets,
    }
    with open(out / "assets.json", "w") as f:
        json.dump(register, f, indent=1)
        f.write("\n")

    # owners.md: assets per owner, project, environment
    counts = {}
    for a in assets:
        key = (a["tags"].get("owner", "(none)"), a["tags"].get("project", "(none)"), a["tags"].get("environment", "(none)"))
        counts[key] = counts.get(key, 0) + 1
    write(out / "owners.md", "\n".join(
        ["# Assets by owner", "", f"Generated {register['generated_at']} from {len(repos)} repositories.", ""]
        + table(["Owner", "Project", "Environment", "Assets"], [(*k, v) for k, v in sorted(counts.items())])))

    write(out / "unowned.md", "\n".join(
        ["# Unowned assets", "", "Tag violations, or an owner outside the team list. Each row needs an owner before the next audit.", ""]
        + table(["Repo", "Resource", "Owner", "Reason"],
                [(a["repo"], f"`{a['id']}`", a["tags"].get("owner", ""), a["unowned_reason"]) for a in unowned])))

    sensitive = [a for a in assets if a["tags"].get("data-class") in ("confidential", "restricted")]
    write(out / "data-classes.md", "\n".join(
        ["# Confidential and restricted assets", "", "Feeds the storage-location inventory of the data classification policy.", ""]
        + table(["Repo", "Resource", "Type", "Data class", "Owner", "Stack", "Region"],
                [(a["repo"], f"`{a['id']}`", a["type"], a["tags"]["data-class"], a["tags"].get("owner", ""), a["stack"], a["region"] or "")
                 for a in sensitive])))

    inventory = load_inventory_module()
    labelled = [dict(a, name=f'{a["name"]} ({a["repo"].split("/")[-1]})', stack=a["repo"] + "/" + a["stack"]) for a in assets]
    dot = inventory.render_dot(labelled)
    write(out / "register.dot", dot)
    if args.svg:
        if shutil.which("dot"):
            subprocess.run(["dot", "-Tsvg", "-o", str(out / "register.svg")], input=dot, text=True, check=True)
        else:
            warn("graphviz dot not installed; SVG not rendered")

    summary = [f"## Asset register: {len(assets)} assets across {len(repos)} repos, {len(unowned)} unowned, "
               f"{len(stale_repos)} stale {'inventory' if len(stale_repos) == 1 else 'inventories'}", ""]
    summary += table(["Repo", "Stack kind", "Resources", "Violations", "Inventory age (days)", "Stale"],
                     [(r["repo"], r["stack_kind"], r["resources"], r["violations"], r["age_days"] if r["age_days"] is not None else "unknown",
                       "yes" if r["stale"] else "") for r in repos])
    if unowned:
        summary += ["", "### Unowned", ""] + table(["Repo", "Resource", "Owner", "Reason"],
                                                   [(a["repo"], f"`{a['id']}`", a["tags"].get("owner", ""), a["unowned_reason"]) for a in unowned[:50]])
        if len(unowned) > 50:
            summary.append(f"\n{len(unowned) - 50} more in unowned.md.")
    write(out / "summary.md", "\n".join(summary))

    with open(out / "SHA256SUMS", "w") as f:
        for name in ("assets.json", "owners.md", "unowned.md", "data-classes.md", "register.dot", "register.svg", "summary.md"):
            p = out / name
            if p.is_file():
                f.write(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {name}\n")

    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write("\n".join(summary) + "\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"repo-count={len(repos)}\nunowned-count={len(unowned)}\nstale-count={len(stale_repos)}\n"
                    f"summary-path={out / 'summary.md'}\n")
    print(f"{TITLE}: {len(assets)} assets, {len(repos)} repos, {len(unowned)} unowned, {len(stale_repos)} stale")
    return 0


if __name__ == "__main__":
    sys.exit(main())
