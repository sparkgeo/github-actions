#!/usr/bin/env bash
# trivy gate. Inputs via env: RESULTS_JSON (trivy image --format json),
# FAIL_ON (critical|high|medium|low|none). Writes per-severity counts and
# max-severity to GITHUB_OUTPUT, a table to GITHUB_STEP_SUMMARY, and one
# job-level annotation per finding. Mapping per docs/gate-policy.md:
#   critical -> CRITICAL; high -> HIGH+; medium -> MEDIUM+;
#   low -> LOW, UNKNOWN and above; none -> never fails.
set -euo pipefail

case "${FAIL_ON}" in
  critical) BLOCK='["CRITICAL"]' ;;
  high)     BLOCK='["CRITICAL","HIGH"]' ;;
  medium|moderate) BLOCK='["CRITICAL","HIGH","MEDIUM"]' ;;
  low)      BLOCK='["CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN"]' ;;
  none)     BLOCK='[]' ;;
  *) echo "::error title=trivy::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

count() { jq --arg s "$1" '[.Results[]?.Vulnerabilities[]? | select(.Severity == $s)] | length' "${RESULTS_JSON}"; }
CRIT=$(count CRITICAL); HIGH=$(count HIGH); MED=$(count MEDIUM); LOW=$(count LOW); UNK=$(count UNKNOWN)
SECRETS=$(jq '[.Results[]?.Secrets[]?] | length' "${RESULTS_JSON}")
TOTAL=$((CRIT+HIGH+MED+LOW+UNK))

if   [ "${CRIT}" -gt 0 ]; then MAX=critical
elif [ "${HIGH}" -gt 0 ]; then MAX=high
elif [ "${MED}"  -gt 0 ]; then MAX=medium
elif [ "${LOW}" -gt 0 ] || [ "${UNK}" -gt 0 ]; then MAX=low
else MAX=none; fi

# One job-level annotation per vulnerability (images have no source line).
jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
  | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion // "no fix")\t\($t)"' "${RESULTS_JSON}" \
  | while IFS=$'\t' read -r sev id pkg inst fix target; do
      case "${sev}" in CRITICAL|HIGH) kind=warning ;; *) kind=notice ;; esac
      echo "::${kind} title=trivy ${sev} ${id}::${pkg} ${inst} (fixed: ${fix}) in ${target}"
    done
jq -r '.Results[]? | .Target as $t | .Secrets[]?
  | "\($t)\t\(.RuleID)\t\(.Title)\t\(.StartLine // 0)"' "${RESULTS_JSON}" \
  | while IFS=$'\t' read -r target rule title line; do
      echo "::error title=trivy secret ${rule}::${title} in ${target}:${line}"
    done

{
  echo "## Trivy image scan"
  echo
  echo "| Severity | Count |"
  echo "|---|---|"
  echo "| CRITICAL | ${CRIT} |"
  echo "| HIGH | ${HIGH} |"
  echo "| MEDIUM | ${MED} |"
  echo "| LOW | ${LOW} |"
  echo "| UNKNOWN | ${UNK} |"
  echo "| Secrets | ${SECRETS} |"
  echo
  echo "Gate: \`fail-on-severity: ${FAIL_ON}\`; highest found: \`${MAX}\`."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "critical-count=${CRIT}"
  echo "high-count=${HIGH}"
  echo "medium-count=${MED}"
  echo "low-count=${LOW}"
  echo "unknown-count=${UNK}"
  echo "secret-count=${SECRETS}"
  echo "max-severity=${MAX}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "trivy: ${TOTAL} vulnerabilit(y/ies) (critical ${CRIT}, high ${HIGH}, medium ${MED}, low ${LOW}, unknown ${UNK}), ${SECRETS} secret(s); threshold '${FAIL_ON}'"

BLOCKED=$(jq --argjson b "${BLOCK}" '[.Results[]?.Vulnerabilities[]? | select(.Severity as $s | $b | index($s))] | length' "${RESULTS_JSON}")
# A secret in an image is always blocking unless the gate is advisory.
if [ "${FAIL_ON}" != "none" ] && [ "${SECRETS}" -gt 0 ]; then
  echo "::error title=trivy::${SECRETS} secret(s) found in the image."
  exit 1
fi
if [ "${BLOCKED}" -gt 0 ]; then
  echo "::error title=trivy::${BLOCKED} vulnerabilit(y/ies) at or above '${FAIL_ON}' severity."
  exit 1
fi
