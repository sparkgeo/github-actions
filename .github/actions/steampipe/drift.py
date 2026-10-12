#!/usr/bin/env python3
"""Live-account drift against the org asset register (issue #117).

Usage: drift.py --live rows.json --register assets.json --output drift.json --report report.md
                [--account ID] [--required-tags owner,project,environment,data-class]

--live is `steampipe query --output json` of aws_tagging_resource (arn, name,
region, account_id, tags). --register is assets.json from the asset-register
roll-up. With --account only live rows and register records of that account
(or records with no account) are compared.

untagged:    live resources missing a required tag
unmanaged:   live resources whose ARN name matches no register identifier
orphaned:    register records whose identifier matches no live ARN
unmatchable: register records without an identifier (cannot be compared)
Exit 0 unless usage error (2). Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import sys
from pathlib import Path

TITLE = "asset-drift"
DEFAULT_REQUIRED = "owner,project,environment,data-class"


def usage_error(msg):
    print(f"::error title={TITLE}::{msg}")
    return 2


def arn_name(arn):
    """Last path or colon segment of the resource part: bucket, function name, role name, vpc id."""
    parts = arn.split(":", 5)
    resource = parts[5] if len(parts) == 6 else arn
    for sep in ("/", ":"):
        if sep in resource:
            resource = resource.rsplit(sep, 1)[1]
    return resource


def load_rows(path):
    with open(path) as f:
        data = json.load(f)
    rows = data.get("rows", data) if isinstance(data, dict) else data
    out = []
    for r in rows:
        tags = r.get("tags") or {}
        if isinstance(tags, str):
            tags = json.loads(tags)
        out.append({"arn": r["arn"], "name": r.get("name"), "region": r.get("region"),
                    "account_id": str(r.get("account_id") or ""), "tags": {str(k): str(v) for k, v in tags.items()}})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", required=True)
    ap.add_argument("--register", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--account", default="")
    ap.add_argument("--required-tags", default=DEFAULT_REQUIRED)
    args = ap.parse_args()
    for p in (args.live, args.register):
        if not Path(p).is_file():
            return usage_error(f"{p} does not exist")
    required = [t.strip() for t in args.required_tags.split(",") if t.strip()]

    live = load_rows(args.live)
    with open(args.register) as f:
        records = json.load(f).get("assets", [])
    if args.account:
        live = [r for r in live if r["account_id"] == args.account]
        records = [a for a in records if a.get("account") in (None, args.account)]
    live.sort(key=lambda r: r["arn"])
    records.sort(key=lambda a: (a.get("repo", ""), a["id"]))

    by_identifier = {}
    for a in records:
        if a.get("identifier"):
            by_identifier.setdefault(a["identifier"], a)

    untagged, unmanaged, managed, matched_ids = [], [], [], set()
    for r in live:
        missing = [k for k in required if k not in r["tags"]]
        if missing:
            untagged.append({"arn": r["arn"], "region": r["region"], "tags": r["tags"], "missing": missing})
        rec = by_identifier.get(arn_name(r["arn"]))
        if rec:
            managed.append({"arn": r["arn"], "repo": rec.get("repo"), "id": rec["id"]})
            matched_ids.add(rec["identifier"])
        else:
            unmanaged.append({"arn": r["arn"], "region": r["region"], "tags": r["tags"]})
    orphaned = [{"repo": a.get("repo"), "id": a["id"], "identifier": a["identifier"], "stack": a.get("stack")}
                for a in records if a.get("identifier") and a["identifier"] not in matched_ids]
    unmatchable = [{"repo": a.get("repo"), "id": a["id"], "stack": a.get("stack")} for a in records if not a.get("identifier")]

    for u in untagged:
        print(f"::warning title={TITLE}::untagged {u['arn']} missing {', '.join(u['missing'])}")
    for u in unmanaged:
        print(f"::warning title={TITLE}::unmanaged {u['arn']} matches no register record")
    for o in orphaned:
        print(f"::warning title={TITLE}::orphaned {o['repo']} {o['id']} ({o['identifier']}) not found in the account")

    out = {"account": args.account or None, "required_tags": required,
           "counts": {"live": len(live), "untagged": len(untagged), "unmanaged": len(unmanaged),
                      "orphaned": len(orphaned), "unmatchable": len(unmatchable), "managed": len(managed)},
           "untagged": untagged, "unmanaged": unmanaged, "orphaned": orphaned, "unmatchable": unmatchable, "managed": managed}
    with open(args.output, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")

    acct = f"account {args.account}" if args.account else "all accounts"
    lines = ["<!-- asset-drift -->",
             f"## Asset drift, {acct}: {len(live)} live resources, {len(untagged)} untagged, {len(unmanaged)} unmanaged, {len(orphaned)} orphaned", ""]
    if untagged:
        lines += ["### Untagged (live, missing required tags)", "", "| ARN | Region | Missing |", "|---|---|---|"]
        lines += [f"| `{u['arn']}` | {u['region'] or ''} | {', '.join(u['missing'])} |" for u in untagged]
        lines.append("")
    if unmanaged:
        lines += ["### Unmanaged (live, not declared in any repository)", "", "| ARN | Region | Owner tag |", "|---|---|---|"]
        lines += [f"| `{u['arn']}` | {u['region'] or ''} | {u['tags'].get('owner', '')} |" for u in unmanaged]
        lines.append("")
    if orphaned:
        lines += ["### Orphaned (declared, absent from the account)", "", "| Repo | Resource | Identifier |", "|---|---|---|"]
        lines += [f"| {o['repo']} | `{o['id']}` | `{o['identifier']}` |" for o in orphaned]
        lines.append("")
    lines.append(f"{len(managed)} live resources matched a register record; {len(unmatchable)} register records have no stated "
                 "identifier and cannot be matched (ids generated at apply time).")
    report = "\n".join(lines) + "\n"
    with open(args.report, "w") as f:
        f.write(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"untagged-count={len(untagged)}\nunmanaged-count={len(unmanaged)}\norphaned-count={len(orphaned)}\n"
                    f"report-path={args.report}\n")
    print(f"{TITLE}: {len(live)} live, {len(untagged)} untagged, {len(unmanaged)} unmanaged, {len(orphaned)} orphaned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
