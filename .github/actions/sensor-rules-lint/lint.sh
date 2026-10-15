#!/usr/bin/env bash
# Validates runtime-sensor rules before deploy (issue #16). Inputs via env:
# SENSOR (falco|tetragon), RULES_DIR, FALCO_IMAGE, ALLOW_ENFORCEMENT,
# KUBECONFORM (binary path), SCHEMA_DIR.
#
# falco:    every *.yaml / *.yml under RULES_DIR is loaded after the image's
#           default falco_rules.yaml with `falco --validate`, so custom rules
#           may use its macros and lists. No kernel driver is needed.
# tetragon: TracingPolicy / TracingPolicyNamespaced files are checked with
#           kubeconform against schemas generated from the Tetragon CRDs
#           (policies/tetragon/schemas), and any enforcement action fails
#           unless ALLOW_ENFORCEMENT is true (Advanced tier: needs a Step 40
#           emulation test and a kill switch first).
set -euo pipefail

mapfile -t files < <(find "${RULES_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "::notice title=sensor-rules-lint::no rules files under ${RULES_DIR}; nothing to validate"
  exit 0
fi

case "${SENSOR}" in
  falco)
    abs="$(cd "${RULES_DIR}" && pwd)"
    args=(-V /etc/falco/falco_rules.yaml)
    for f in "${files[@]}"; do args+=(-V "/rules/${f#"${RULES_DIR%/}/"}"); done
    set +e
    out="$(docker run --rm -v "${abs}:/rules:ro" "${FALCO_IMAGE}" falco "${args[@]}" 2>&1)"
    rc=$?
    set -e
    echo "${out}"
    if [ "${rc}" -ne 0 ]; then
      err="$(grep -m1 -E 'LOAD_ERR|Error|error' <<< "${out}" || echo "falco --validate exited ${rc}")"
      echo "::error title=sensor-rules-lint (falco)::${err}"
      exit 1
    fi
    ;;
  tetragon)
    rc=0
    "${KUBECONFORM}" -strict -summary -output text \
      -schema-location "${SCHEMA_DIR}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "${files[@]}" || rc=1
    if [ "${ALLOW_ENFORCEMENT}" != "true" ]; then
      # Actions that kill, override a return value, or signal the process.
      while IFS=: read -r file line text; do
        action="$(grep -oE 'Sigkill|Override|NotifyEnforcer|Signal' <<< "${text}")"
        echo "::error file=${file},line=${line},title=sensor-rules-lint (tetragon)::enforcement action ${action} is Advanced tier only; set allow-enforcement after a Step 40 emulation test"
        rc=1
      done < <(grep -nHE '^[[:space:]]*-?[[:space:]]*action:[[:space:]]*"?(Sigkill|Override|NotifyEnforcer|Signal)"?[[:space:]]*$' "${files[@]}" || true)
    fi
    exit "${rc}"
    ;;
  *)
    echo "::error title=sensor-rules-lint::sensor must be falco or tetragon, got '${SENSOR}'"
    exit 1
    ;;
esac
