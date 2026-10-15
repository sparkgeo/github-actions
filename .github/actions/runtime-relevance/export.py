#!/usr/bin/env python3
"""Build runtime-relevance.json from a collect.sh dump (issue #179).

Usage: export.py --input DIR --output FILE [--cluster NAME] [--now ISO8601]

Kubescape (kubevuln 0.3, chart 1.40) writes two kinds of
VulnerabilityManifest, told apart by the label kubescape.io/context:
"non-filtered", one per image (every CVE in it), and "filtered", one per
workload container, scanned from only the files that container loaded and
labelled with kubescape.io/workload-namespace, -kind, -name and
-container-name. Both carry the image digest in the kubescape.io/image-id
annotation. For each workload container, every CVE in its image's manifest
becomes an entry, relevant: true when the filtered manifest lists the same
CVE and package and false when it does not. A workload with a
VulnerabilityManifestSummary but no filtered manifest yet (the node agent is
still learning) gets "unknown" for every CVE. Trivy Operator findings for an
image digest Kubescape has not scanned are added as "unknown", so the export
covers every running image either tool saw.

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

    images, filtered = {}, []
    for p in sorted(glob.glob(os.path.join(a.input, "manifests", "*.json"))):
        m = load(p)
        md = m.get("metadata") or {}
        context = (md.get("labels") or {}).get("kubescape.io/context")
        image = digest((md.get("annotations") or {}).get("kubescape.io/image-id"))
        if context == "filtered":
            filtered.append(m)
        elif context == "non-filtered":
            images[image] = m

    def key(labels, prefix="kubescape.io/workload-"):
        return tuple((labels.get(prefix + k) or "").lower() for k in ("namespace", "kind", "name", "container-name"))

    def emit(all_m, image, labels, loaded, last_seen):
        ns, kind, name, container = (labels.get("kubescape.io/workload-" + k, "") for k in
                                     ("namespace", "kind", "name", "container-name"))
        for (cve, pkg), (adv, ver) in sorted(pairs(all_m).items()):
            entries.append({
                "image": image, "workload": f"{ns}/{kind}/{name}", "container": container,
                "cve": cve, "advisory": adv, "package": pkg, "version": ver,
                "relevant": "unknown" if loaded is None else (cve, pkg) in loaded,
                "last_seen": last_seen, "source": "kubescape",
            })

    entries, seen_images, done = [], set(), set()
    for f in filtered:
        md = f.get("metadata") or {}
        image = digest((md.get("annotations") or {}).get("kubescape.io/image-id"))
        all_m = images.get(image)
        if not all_m:
            continue  # image-wide scan not stored yet; the next run picks it up
        labels = md.get("labels") or {}
        emit(all_m, image, labels, set(pairs(f)), created(f))
        seen_images.add(image)
        done.add(key(labels))

    # Workloads Kubescape knows about but has no filtered manifest for yet.
    for s in load(os.path.join(a.input, "summaries.json")).get("items") or []:
        md = s.get("metadata") or {}
        labels = md.get("labels") or {}
        image = digest((md.get("annotations") or {}).get("kubescape.io/image-id"))
        if key(labels) in done or image not in images:
            continue
        emit(images[image], image, labels, None, created(images[image]))
        seen_images.add(image)
        done.add(key(labels))

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
