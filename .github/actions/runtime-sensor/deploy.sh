#!/usr/bin/env bash
# Installs or upgrades the runtime sensor into the current kubectl context
# (issue #16). Inputs via env: SENSOR (falco|tetragon), RULES_DIR, NAMESPACE,
# FALCO_VERSION, FALCO_SHA256, TETRAGON_VERSION, TETRAGON_SHA256,
# SIDEKICK_WEBHOOK (falco: forward alerts, e.g. to Wazuh), EXTRA_VALUES,
# TIMEOUT. Charts are fetched by pinned version and checked against SHA-256.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fetch() {  # <url> <sha256> <out>
  curl -sSfL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || { echo "::error title=runtime-sensor::checksum mismatch for $1"; exit 1; }
}

# Each chart's usual home unless the caller names one.
if [ -z "${NAMESPACE:-}" ]; then
  if [ "${SENSOR}" = tetragon ]; then NAMESPACE=kube-system; else NAMESPACE=falco; fi
fi

mapfile -t files < <(find "${RULES_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)
extra=()
[ -z "${EXTRA_VALUES:-}" ] || extra=(-f "${EXTRA_VALUES}")

case "${SENSOR}" in
  falco)
    fetch "https://github.com/falcosecurity/charts/releases/download/falco-${FALCO_VERSION}/falco-${FALCO_VERSION}.tgz" \
      "${FALCO_SHA256}" "${TMP}/falco.tgz"
    # Values as JSON (valid YAML): each custom rules file becomes one entry of
    # customRules, mounted next to the default rules.
    python3 -I - "${TMP}/values.json" "${SIDEKICK_WEBHOOK:-}" "${files[@]}" <<'PY'
import json, os, sys
out, webhook, files = sys.argv[1], sys.argv[2], sys.argv[3:]
v = {
    "driver": {"kind": "modern_ebpf"},
    "tty": True,
    "collectors": {"kubernetes": {"enabled": True}},
    "customRules": {f"{i:02d}-{os.path.basename(p)}": open(p, encoding="utf-8").read() for i, p in enumerate(files)},
}
if webhook:
    v["falcosidekick"] = {"enabled": True, "config": {"webhook": {"address": webhook}}}
json.dump(v, open(out, "w"), indent=1)
PY
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
    helm upgrade --install falco "${TMP}/falco.tgz" -n "${NAMESPACE}" -f "${TMP}/values.json" "${extra[@]}" \
      --wait --timeout "${TIMEOUT:-10m}"
    chart="falco ${FALCO_VERSION} (modern_ebpf)"
    ;;
  tetragon)
    fetch "https://helm.cilium.io/tetragon-${TETRAGON_VERSION}.tgz" "${TETRAGON_SHA256}" "${TMP}/tetragon.tgz"
    helm upgrade --install tetragon "${TMP}/tetragon.tgz" -n "${NAMESPACE}" --create-namespace "${extra[@]}" \
      --wait --timeout "${TIMEOUT:-10m}"
    # The operator registers the TracingPolicy CRDs once it is up.
    kubectl wait --for condition=established --timeout 120s crd/tracingpolicies.cilium.io crd/tracingpoliciesnamespaced.cilium.io
    [ "${#files[@]}" -eq 0 ] || kubectl apply -f "${RULES_DIR}"
    chart="tetragon ${TETRAGON_VERSION}"
    ;;
  *)
    echo "::error title=runtime-sensor::sensor must be falco or tetragon, got '${SENSOR}'"
    exit 1
    ;;
esac

{
  echo "### Runtime sensor"
  echo
  echo "| Sensor | Namespace | Custom rules files |"
  echo "|---|---|---|"
  echo "| ${chart} | ${NAMESPACE} | ${#files[@]} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${SENSOR}"
