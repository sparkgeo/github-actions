#!/usr/bin/env bash
# Installs or upgrades Trivy Operator and the Kubescape operator (relevancy on)
# into the current kubectl context (issue #179). Inputs via env: NAMESPACE,
# CLUSTER_NAME, EXCLUDE_NAMESPACES (comma-separated), NAMESPACE_LABELS
# (space-separated key=value), TRIVY_VERSION, TRIVY_SHA256, KUBESCAPE_VERSION,
# KUBESCAPE_SHA256, TRIVY_VALUES and KUBESCAPE_VALUES (optional extra values
# files), TIMEOUT. Charts are fetched from their GitHub releases and checked
# against the pinned SHA-256 before install.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fetch_chart() {  # <repo> <chart> <version> <sha256>: prints the local path
  local url="https://github.com/$1/releases/download/$2-$3/$2-$3.tgz" out="${TMP}/$2-$3.tgz"
  curl -sSfL -o "${out}" "${url}"
  echo "$4  ${out}" | sha256sum -c --quiet - >&2 || { echo "::error title=runtime-scanners::$2 $3 checksum mismatch" >&2; exit 1; }
  echo "${out}"
}

trivy_chart="$(fetch_chart aquasecurity/helm-charts trivy-operator "${TRIVY_VERSION}" "${TRIVY_SHA256}")"
ks_chart="$(fetch_chart kubescape/helm-charts kubescape-operator "${KUBESCAPE_VERSION}" "${KUBESCAPE_SHA256}")"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
# Tagging standard (#114): owner, project, environment, data-class, exposure.
read -ra labels <<< "${NAMESPACE_LABELS}"
[ "${#labels[@]}" -eq 0 ] || kubectl label namespace "${NAMESPACE}" --overwrite "${labels[@]}" > /dev/null

# Scanners never scan themselves or the control plane; callers add CI runner
# namespaces and the like through EXCLUDE_NAMESPACES.
exclude="${NAMESPACE},kube-system,kube-public,kube-node-lease${EXCLUDE_NAMESPACES:+,${EXCLUDE_NAMESPACES}}"

cat > "${TMP}/trivy.yaml" <<YAML
excludeNamespaces: "${exclude}"
operator:
  vulnerabilityScannerEnabled: true
  # Only what the runtime-relevance export needs; the rest is Kubescape's job
  # or checkov's (#60) at build time.
  configAuditScannerEnabled: false
  rbacAssessmentScannerEnabled: false
  infraAssessmentScannerEnabled: false
  clusterComplianceEnabled: false
  exposedSecretScannerEnabled: false
YAML

cat > "${TMP}/kubescape.yaml" <<YAML
clusterName: "${CLUSTER_NAME}"
ksNamespace: "${NAMESPACE}"
excludeNamespaces: "${exclude}"
capabilities:
  vulnerabilityScan: enable
  relevancy: enable
  runtimeObservability: enable
  configurationScan: disable
  continuousScan: disable
  nodeScan: disable
  networkPolicyService: disable
  seccompProfileService: disable
  nodeProfileService: disable
  runtimeDetection: disable
  malwareDetection: disable
  autoUpgrading: disable
YAML

extra() { [ -z "${1:-}" ] || printf -- '-f\n%s\n' "$1"; }
mapfile -t trivy_extra < <(extra "${TRIVY_VALUES:-}")
mapfile -t ks_extra < <(extra "${KUBESCAPE_VALUES:-}")

helm upgrade --install trivy-operator "${trivy_chart}" -n "${NAMESPACE}" \
  -f "${TMP}/trivy.yaml" "${trivy_extra[@]}" --wait --timeout "${TIMEOUT:-10m}"
helm upgrade --install kubescape "${ks_chart}" -n "${NAMESPACE}" \
  -f "${TMP}/kubescape.yaml" "${ks_extra[@]}" --wait --timeout "${TIMEOUT:-10m}"

{
  echo "### Runtime scanners on \`${CLUSTER_NAME}\`"
  echo
  echo "| Release | Chart | Namespace |"
  echo "|---|---|---|"
  echo "| trivy-operator | trivy-operator ${TRIVY_VERSION} | ${NAMESPACE} |"
  echo "| kubescape | kubescape-operator ${KUBESCAPE_VERSION} (relevancy on) | ${NAMESPACE} |"
  echo
  echo "Excluded namespaces: \`${exclude}\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
kubectl get pods -n "${NAMESPACE}"
