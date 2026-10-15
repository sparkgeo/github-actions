#!/usr/bin/env bash
# Dumps what the runtime-relevance exporter reads from the current kubectl
# context into OUT_DIR (issue #179): Kubescape VulnerabilityManifestSummaries,
# the two VulnerabilityManifests each one references (all CVEs in the image;
# CVEs in packages the workload loaded), and Trivy Operator
# VulnerabilityReports. Missing CRDs give empty lists, not a failure.
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

# The list call does not carry the manifests' payloads; fetch each one.
jq -r '.items[].spec.vulnerabilitiesRef | .all, .relevant | select(. != null and .name != "") | "\(.namespace) \(.name)"' \
  "${OUT}/summaries.json" | sort -u | while read -r ns name; do
  kubectl get vulnerabilitymanifests.spdx.softwarecomposition.kubescape.io -n "${ns}" "${name}" -o json \
    > "${OUT}/manifests/${ns}__${name}.json" 2>/dev/null \
    || echo "::warning title=runtime-relevance::manifest ${ns}/${name} not readable"
done
echo "collected $(jq '.items | length' "${OUT}/summaries.json") summaries, $(find "${OUT}/manifests" -name '*.json' | wc -l) manifests, $(jq '.items | length' "${OUT}/trivy.json") trivy reports"
