#!/usr/bin/env python3
"""RoPA as code: schema validation and completeness checks (issue #119).

Usage: check.py --ropa ropa.yml --schema policies/privacy/ropa.schema.json
                [--inventory inventory.json] [--privado report.json | privado.json]
                [--fail-on none|missing|all] [--comment comment.md] [--output report.json]

Runs in a virtualenv with PyYAML and jsonschema. Checks:
1. ropa.yml validates against the schema (always an error).
2. Every inventory resource tagged data-class confidential or restricted
   appears in some activity's stores (missing row).
3. Every third-party sink in the privado report matches some activity's
   sinks by name, sink id or destination domain (missing processor).
4. Stores or sinks named in ropa.yml that the inventory or report does not
   know (orphan); purpose or lawful_basis that is a placeholder (TBD, ?, -).
fail-on: none (report only), missing (2 and 3 and placeholders fail), all
(orphans fail too). Schema errors always fail. Standard library plus the two
packages.
"""

import argparse
import json
import os
import re
import sys
from urllib.parse import urlparse

import yaml
from jsonschema import Draft202012Validator

PLACEHOLDERS = {"", "tbd", "todo", "?", "-", "n/a", "none"}


def load_yaml(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def load_json(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def privado_sinks(report):
    """{sink id: {destinations}} for third parties, from report.json (#99) or raw privado.json."""
    out = {}
    if "sinks" in report and isinstance(report["sinks"], dict) and "third_parties" in report["sinks"]:
        for sid, d in report["sinks"]["third_parties"].items():
            out[sid] = set(d.get("destinations", []))
        return out
    for entry in (report.get("dataFlow") or {}).get("third_parties", []):
        for sink in entry.get("sinks", []):
            dests = [u.strip('"') for u in sink.get("apiUrl", [])] or list(sink.get("domains", []))
            out.setdefault(sink.get("id", ""), set()).update(dests)
    return out


def host(dest):
    return (urlparse(dest).hostname or dest).lower() if "://" in dest else dest.lower()


def sink_matches(name, sid, dests):
    n = name.lower()
    return n in sid.lower() or any(n in host(d) for d in dests)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ropa", default="ropa.yml")
    ap.add_argument("--schema", required=True)
    ap.add_argument("--inventory", default="")
    ap.add_argument("--privado", default="")
    ap.add_argument("--fail-on", default="missing", choices=["none", "missing", "all"])
    ap.add_argument("--comment", default="")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    schema_errors, missing, orphans, warnings = [], [], [], []
    if not os.path.exists(args.ropa):
        schema_errors.append(f"{args.ropa} does not exist; copy docs/examples/ropa.yml and fill it in")
        ropa = {"activities": []}
    else:
        try:
            ropa = load_yaml(args.ropa) or {}
        except yaml.YAMLError as e:
            schema_errors.append(f"{args.ropa}: not valid YAML: {str(e).splitlines()[0]}")
            ropa = {"activities": []}
        if not isinstance(ropa, dict):
            schema_errors.append(f"{args.ropa}: must be a mapping with an activities list")
            ropa = {"activities": []}
        schema = load_json(args.schema)
        for err in sorted(Draft202012Validator(schema).iter_errors(ropa), key=lambda e: list(e.path)):
            where = "/".join(str(p) for p in err.absolute_path) or "(root)"
            schema_errors.append(f"{args.ropa}: {where}: {err.message}")
    activities = [a for a in ropa.get("activities", []) if isinstance(a, dict)]

    for a in activities:
        aid = a.get("id", "?")
        for field in ("purpose", "lawful_basis"):
            if str(a.get(field, "")).strip().lower() in PLACEHOLDERS:
                missing.append(f"activity {aid}: {field} is empty or a placeholder")
        if a.get("lawful_basis") == "legitimate_interests" and not a.get("lia"):
            missing.append(f"activity {aid}: legitimate_interests needs an lia assessment path")
        if a.get("sinks") and not a.get("processor_dpa"):
            warnings.append(f"activity {aid}: sinks declared but no processor_dpa")

    declared_stores = {s for a in activities for s in a.get("stores", [])}
    declared_sinks = {s for a in activities for s in a.get("sinks", [])}

    inventory = load_json(args.inventory) if args.inventory else None
    inv_ids, sensitive = set(), {}
    if inventory is not None:
        for r in inventory.get("resources", []):
            inv_ids.add(r.get("id", ""))
            cls = (r.get("tags") or {}).get("data-class", "").lower()
            if cls in ("confidential", "restricted"):
                sensitive[r["id"]] = cls
        for rid, cls in sorted(sensitive.items()):
            if rid not in declared_stores:
                missing.append(f"store {rid} (data-class {cls}) has no activity in {args.ropa}")
        for s in sorted(declared_stores - inv_ids):
            orphans.append(f"store {s} is not in the inventory (renamed or removed?)")
        for a in activities:
            for s in a.get("stores", []):
                if s in sensitive and a.get("classification") == "internal":
                    warnings.append(f"activity {a.get('id')}: classification internal but store {s} is data-class {sensitive[s]}")
    else:
        warnings.append("no inventory given: store completeness not checked")

    report = load_json(args.privado) if args.privado else None
    matched_sinks = set()
    if report is not None:
        sinks = privado_sinks(report)
        for sid, dests in sorted(sinks.items()):
            names = [n for n in declared_sinks if sink_matches(n, sid, dests)]
            if names:
                matched_sinks.update(names)
            else:
                missing.append(f"third-party sink {sid} ({', '.join(sorted(host(d) for d in dests)) or 'no destination'}) is in the privado report but in no activity's sinks")
        for n in sorted(declared_sinks - matched_sinks):
            orphans.append(f"sink {n} matches no third-party sink in the privado report (processor no longer used?)")
    else:
        warnings.append("no privado report given: processor completeness not checked")

    errors = list(schema_errors)
    if args.fail_on in ("missing", "all"):
        errors += missing
    if args.fail_on == "all":
        errors += orphans
    advisories = [m for m in missing + orphans if m not in errors] + warnings

    for e in errors:
        print(f"::error title=ropa::{e}")
    for w in advisories:
        print(f"::warning title=ropa::{w}")

    lines = [f"## RoPA check: {len(activities)} activit{'y' if len(activities) == 1 else 'ies'}, {len(sensitive)} sensitive store(s) in the inventory, "
             f"{len(schema_errors)} schema error(s), {len(missing)} missing, {len(orphans)} orphan(s) (fail-on: {args.fail_on})", ""]
    if activities:
        lines += ["| Activity | Lawful basis | Classification | Stores | Processors | Retention | Owner |", "|---|---|---|---|---|---|---|"]
        for a in activities:
            lines.append(f"| `{a.get('id', '?')}` | {a.get('lawful_basis', '')} | {a.get('classification', '')} | {', '.join(a.get('stores', []))} | {', '.join(a.get('sinks', [])) or '-'} | {a.get('retention', '')} | {a.get('owner', '')} |")
    for title, items in (("Schema errors", schema_errors), ("Missing rows", missing), ("Orphaned references", orphans), ("Notes", warnings)):
        if items:
            lines += ["", f"### {title}", ""] + [f"- {i}" for i in items]
    lines += ["", "Field guide: docs/ropa.md (GDPR Art. 30 mapping). Stores come from the asset inventory (#115), processors from the privado data-flow report (#99)."]
    text = "\n".join(lines) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    if args.comment:
        with open(args.comment, "w") as fh:
            fh.write("<!-- ropa-check -->\n" + text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"activity-count={len(activities)}\nmissing-count={len(missing)}\norphan-count={len(orphans)}\nerror-count={len(errors)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"activities": [a.get("id") for a in activities], "schema_errors": schema_errors, "missing": missing,
                       "orphans": orphans, "warnings": warnings, "errors": errors}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
