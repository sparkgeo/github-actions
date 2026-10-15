"""Validate reviewed OpenVEX statements, flag stale ones against the SBOM,
and write a CycloneDX VEX copy for Dependency-Track (issue #232).

Usage: vex.py --statements DIR --sbom SBOM.json --cyclonedx OUT.json
DIR holds one OpenVEX document per decision (*.json, as `vexctl create`
writes them). Every statement needs a vulnerability name, at least one
product, a valid status, a justification when not_affected and an action
statement when affected; any violation is an ::error and exit 1. A statement
none of whose package URLs (subcomponents, else products) appears in the SBOM
is reported stale. Prints statement-count and stale-count for GITHUB_OUTPUT.
"""

import argparse
import json
import os
import sys
from pathlib import Path

STATUSES = {"not_affected", "affected", "fixed", "under_investigation"}
JUSTIFICATIONS = {
    # OpenVEX justification -> CycloneDX analysis.justification
    "component_not_present": "code_not_present",
    "vulnerable_code_not_present": "code_not_present",
    "vulnerable_code_not_in_execute_path": "code_not_reachable",
    "vulnerable_code_cannot_be_controlled_by_adversary": "requires_environment",
    "inline_mitigations_already_exist": "protected_by_mitigating_control",
}
STATES = {"not_affected": "not_affected", "affected": "exploitable", "fixed": "resolved",
          "under_investigation": "in_triage"}


def strip_qualifiers(purl):
    return purl.split("?")[0].split("#")[0]


def sbom_refs(path):
    """purl (without qualifiers) -> bom-ref, from CycloneDX components or SPDX packages."""
    doc = json.loads(Path(path).read_text())
    refs = {}

    def walk(components):
        for c in components or []:
            if c.get("purl"):
                refs.setdefault(strip_qualifiers(c["purl"]), c.get("bom-ref") or c["purl"])
            walk(c.get("components"))

    walk(doc.get("components"))
    for pkg in doc.get("packages", []):
        for ref in pkg.get("externalRefs", []):
            if ref.get("referenceType") == "purl":
                refs.setdefault(strip_qualifiers(ref["referenceLocator"]), ref["referenceLocator"])
    return refs


def check(path, doc):
    errors = []
    if not str(doc.get("@context", "")).startswith("https://openvex.dev/ns"):
        errors.append("not an OpenVEX document (@context)")
    statements = doc.get("statements") or []
    if not statements:
        errors.append("no statements")
    for i, st in enumerate(statements, 1):
        where = f"statement {i}"
        if not (st.get("vulnerability") or {}).get("name"):
            errors.append(f"{where}: vulnerability.name missing")
        if not [p for p in st.get("products") or [] if p.get("@id")]:
            errors.append(f"{where}: no product @id")
        status = st.get("status")
        if status not in STATUSES:
            errors.append(f"{where}: status '{status}' is not one of {', '.join(sorted(STATUSES))}")
        if status == "not_affected" and st.get("justification") not in JUSTIFICATIONS:
            errors.append(f"{where}: not_affected needs a justification ({', '.join(sorted(JUSTIFICATIONS))})")
        if status == "affected" and not st.get("action_statement"):
            errors.append(f"{where}: affected needs an action_statement")
    for e in errors:
        print(f"::error file={path},title=vex::{e}", file=sys.stderr)
    return not errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--statements", required=True)
    ap.add_argument("--sbom", required=True)
    ap.add_argument("--cyclonedx", required=True)
    args = ap.parse_args()

    refs = sbom_refs(args.sbom)
    files = sorted(Path(args.statements).glob("*.json"))
    if not files:
        sys.exit(f"::error title=vex::no OpenVEX documents (*.json) in {args.statements}")
    ok, vulns, rows, stale = True, [], [], 0
    for path in files:
        doc = json.loads(path.read_text())
        if not check(path, doc):
            ok = False
            continue
        for st in doc["statements"]:
            # OpenVEX 0.2 nests subcomponents under each product; 0.0.x had them on the statement.
            subs = [c for p in st["products"] for c in p.get("subcomponents") or []] + (st.get("subcomponents") or [])
            ids = [c["@id"] for c in subs if c.get("@id")] or [p["@id"] for p in st["products"]]
            matched = [refs[strip_qualifiers(i)] for i in ids if strip_qualifiers(i) in refs]
            name = st["vulnerability"]["name"]
            if not matched:
                stale += 1
                print(f"::warning file={path},title=vex::{name}: none of {', '.join(ids)} is in the SBOM; "
                      "the statement is stale (remove it, or update the package URL)", file=sys.stderr)
            analysis = {"state": STATES[st["status"]]}
            if st.get("justification"):
                analysis["justification"] = JUSTIFICATIONS[st["justification"]]
            detail = st.get("impact_statement") or st.get("action_statement") or st.get("status_notes")
            if detail:
                analysis["detail"] = detail
            vulns.append({"id": name, "analysis": analysis,
                          "affects": [{"ref": r} for r in matched or ids]})
            rows.append(f"| {name} | {st['status']} | {st.get('justification', '-')} | "
                        f"{', '.join(ids)} | `{path.name}` | {'stale' if not matched else 'in SBOM'} |")
    if not ok:
        sys.exit(1)

    Path(args.cyclonedx).write_text(json.dumps(
        {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1, "vulnerabilities": vulns}, indent=2))
    summary = ["### VEX statements", "", "| Vulnerability | Status | Justification | Packages | File | SBOM |",
               "|---|---|---|---|---|---|", *rows]
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(summary) + "\n")
    print(f"statement-count={len(vulns)}")
    print(f"stale-count={stale}")


if __name__ == "__main__":
    main()
