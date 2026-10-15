#!/usr/bin/env bash
# Dumps what the runtime-relevance exporter reads from the current kubectl
# context into OUT_DIR (issue #179): Kubescape VulnerabilityManifestSummaries
# and VulnerabilityManifests (all CVEs in an image; CVEs in the packages a
# workload loaded), and Trivy Operator VulnerabilityReports. Missing CRDs give empty lists, not a failure.
set -euo pipefail
OUT="${OUT_DIR:?}"
mkdir -p "${OUT}/manifests"

list() {  # <resource> <file>
  if ! kubectl get "$1" -A -o json > "${OUT}/$2" 2>/dev/null; then
    echo "::warning title=runtime-relevance::no $1 in this cluster"
    echo '{"items":[]}' > "${OUT}/$2"
  fi
}
list vulnerabilitymanifestsummaries.spdx.softwarecomposition.kubescape.io summaries.json
list vulnerabilityreports.aquasecurity.github.io trivy.json

# Every VulnerabilityManifest: image-wide ones (label kubescape.io/context
# non-filtered) and per-workload ones holding only CVEs in loaded packages
# (filtered). The list call may omit payloads, so fetch each one.
kubectl get vulnerabilitymanifests.spdx.softwarecomposition.kubescape.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      [ -n "${name}" ] || continue
      kubectl get vulnerabilitymanifests.spdx.softwarecomposition.kubescape.io -n "${ns}" "${name}" -o json \
        > "${OUT}/manifests/${ns}__${name}.json" 2>/dev/null \
        || echo "::warning title=runtime-relevance::manifest ${ns}/${name} not readable"
    done
echo "collected $(jq '.items | length' "${OUT}/summaries.json") summaries, $(find "${OUT}/manifests" -name '*.json' | wc -l) manifests, $(jq '.items | length' "${OUT}/trivy.json") trivy reports"
