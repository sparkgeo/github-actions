#!/usr/bin/env python3
"""Build runtime-relevance.json from a collect.sh dump (issue #179).

Usage: export.py --input DIR --output FILE [--cluster NAME] [--now ISO8601]

For each Kubescape VulnerabilityManifestSummary (one per workload container):
every CVE in the image's manifest ("all") becomes an entry; it is
relevant: true when the workload's filtered manifest ("relevant") lists the
same CVE and package, false when that manifest exists and does not, and
"unknown" when the node agent has produced no filtered manifest yet. Trivy
Operator findings for an image digest Kubescape has no entry for are added
as "unknown", so the export covers every running image either tool saw.

Output: {"generated_at", "cluster", "counts": {...}, "entries": [{"image",
"workload", "container", "cve", "advisory", "package", "version",
"relevant", "last_seen", "source"}]}. #80's override reads `package`, `cve`
and `relevant`. Standard library only; run with python3 -I.
"""

import argparse
import glob
import json
import os
import re
from datetime import datetime, timezone

CVE = re.compile(r"^CVE-\d{4}-\d+$")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def digest(ref):
    m = DIGEST.search(ref or "")
    return m.group(0) if m else (ref or "")


def cve_of(match):
    """Grype match -> (cve or advisory id, advisory id)."""
    v = match.get("vulnerability") or {}
    ids = [v.get("id", "")] + [r.get("id", "") for r in match.get("relatedVulnerabilities") or []]
    cve = next((i for i in ids if CVE.match(i)), ids[0])
    return cve, v.get("id", "")


def pairs(manifest):
    out = {}
    for m in ((manifest.get("spec") or {}).get("payload") or {}).get("matches") or []:
        cve, adv = cve_of(m)
        a = m.get("artifact") or {}
        out[(cve, a.get("name", ""))] = (adv, a.get("version", ""))
    return out


def created(manifest):
    meta = (manifest.get("spec") or {}).get("metadata") or {}
    return ((meta.get("report") or {}).get("createdAt")
            or (manifest.get("metadata") or {}).get("creationTimestamp") or "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--cluster", default="")
    ap.add_argument("--now", default="")
    a = ap.parse_args()

    manifests = {}
    for p in glob.glob(os.path.join(a.input, "manifests", "*.json")):
        m = load(p)
        md = m.get("metadata") or {}
        manifests[(md.get("namespace", ""), md.get("name", ""))] = m

    entries, seen_images = [], set()
    for s in load(os.path.join(a.input, "summaries.json")).get("items") or []:
        labels = (s.get("metadata") or {}).get("labels") or {}
        ref = (s.get("spec") or {}).get("vulnerabilitiesRef") or {}
        all_ref, rel_ref = ref.get("all") or {}, ref.get("relevant") or {}
        all_m = manifests.get((all_ref.get("namespace", ""), all_ref.get("name", "")))
        if not all_m:
            continue
        rel_m = manifests.get((rel_ref.get("namespace", ""), rel_ref.get("name", ""))) if rel_ref.get("name") else None
        ann = (all_m.get("metadata") or {}).get("annotations") or {}
        image = digest(ann.get("kubescape.io/image-id") or ann.get("kubescape.io/image-tag"))
        seen_images.add(image)
        workload = "/".join(labels.get(k, "") for k in (
            "kubescape.io/workload-namespace", "kubescape.io/workload-kind", "kubescape.io/workload-name"))
        container = labels.get("kubescape.io/workload-container-name", "")
        loaded = pairs(rel_m) if rel_m else None
        last_seen = created(rel_m) if rel_m else created(all_m)
        for (cve, pkg), (adv, ver) in sorted(pairs(all_m).items()):
            entries.append({
                "image": image, "workload": workload, "container": container,
                "cve": cve, "advisory": adv, "package": pkg, "version": ver,
                "relevant": "unknown" if loaded is None else (cve, pkg) in loaded,
                "last_seen": last_seen, "source": "kubescape",
            })

    for r in load(os.path.join(a.input, "trivy.json")).get("items") or []:
        rep = r.get("report") or {}
        image = digest((rep.get("artifact") or {}).get("digest"))
        if not image or image in seen_images:
            continue
        labels = (r.get("metadata") or {}).get("labels") or {}
        workload = "/".join(labels.get(k, "") for k in (
            "trivy-operator.resource.namespace", "trivy-operator.resource.kind", "trivy-operator.resource.name"))
        for v in rep.get("vulnerabilities") or []:
            entries.append({
                "image": image, "workload": workload, "container": labels.get("trivy-operator.container.name", ""),
                "cve": v.get("vulnerabilityID", ""), "advisory": v.get("vulnerabilityID", ""),
                "package": v.get("resource", ""), "version": v.get("installedVersion", ""),
                "relevant": "unknown", "last_seen": (rep.get("updateTimestamp") or ""), "source": "trivy-operator",
            })

    counts = {"entries": len(entries)}
    for k in (True, False, "unknown"):
        counts[str(k).lower()] = sum(1 for e in entries if e["relevant"] == k)
    out = {
        "generated_at": a.now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cluster": a.cluster, "counts": counts, "entries": entries,
    }
    with open(a.output, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print(f"runtime-relevance: {counts['entries']} entries, {counts['true']} loaded, "
          f"{counts['false']} not loaded, {counts['unknown']} unknown")


if __name__ == "__main__":
    main()
