#!/usr/bin/env bash
# k8s-scan gate. Inputs via env: RESULTS_DIR (trivy JSON files: charts.json
# from `trivy fs` on the charts dir, kustomize-*.json from `trivy config` on
# rendered overlays, image-*.json from `trivy image`), FAIL_ON
# (critical|high|medium|low|none). Writes per-severity counts and
# max-severity to GITHUB_OUTPUT, a table to GITHUB_STEP_SUMMARY, and one
# annotation per finding: inline when the Target is a file in the repo
# (Helm templates and values), job-level otherwise (rendered overlays,
# images). Mapping per docs/gate-policy.md: critical -> CRITICAL;
# high -> HIGH+; medium -> MEDIUM+; low -> LOW, UNKNOWN and above;
# none -> never fails. Secrets always block unless the gate is none.
set -euo pipefail

case "${FAIL_ON}" in
  critical) BLOCK='["CRITICAL"]' ;;
  high)     BLOCK='["CRITICAL","HIGH"]' ;;
  medium|moderate) BLOCK='["CRITICAL","HIGH","MEDIUM"]' ;;
  low)      BLOCK='["CRITICAL","HIGH","MEDIUM","LOW","UNKNOWN"]' ;;
  none)     BLOCK='[]' ;;
  *) echo "::error title=trivy::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

shopt -s nullglob
files=("${RESULTS_DIR}"/*.json)
if [ "${#files[@]}" -eq 0 ]; then
  echo "::warning title=trivy::no result files under ${RESULTS_DIR}"
  { echo "critical-count=0"; echo "high-count=0"; echo "medium-count=0"; echo "low-count=0"; echo "secret-count=0"; echo "max-severity=none"; } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# Misconfigurations (Status FAIL) and vulnerabilities share one severity
# scale; secrets are counted separately.
count() { jq -n --arg s "$1" '[inputs | .Results[]? | (.Misconfigurations[]? | select(.Status == "FAIL")), .Vulnerabilities[]? | select(.Severity == $s)] | length' "${files[@]}"; }
CRIT=$(count CRITICAL); HIGH=$(count HIGH); MED=$(count MEDIUM); LOW=$(count LOW); UNK=$(count UNKNOWN)
SECRETS=$(jq -n '[inputs | .Results[]?.Secrets[]?] | length' "${files[@]}")
MISCONF=$(jq -n '[inputs | .Results[]?.Misconfigurations[]? | select(.Status == "FAIL")] | length' "${files[@]}")
VULNS=$(jq -n '[inputs | .Results[]?.Vulnerabilities[]?] | length' "${files[@]}")

if   [ "${CRIT}" -gt 0 ]; then MAX=critical
elif [ "${HIGH}" -gt 0 ]; then MAX=high
elif [ "${MED}"  -gt 0 ]; then MAX=medium
elif [ "${LOW}" -gt 0 ] || [ "${UNK}" -gt 0 ]; then MAX=low
else MAX=none; fi

# Misconfigurations: inline when the target is a repo file (Helm template
# or values file, path already prefixed with the scanned directory).
jq -r '.Results[]? | .Target as $t | .Misconfigurations[]? | select(.Status == "FAIL")
  | "\(.Severity)\t\(.ID)\t\(.CauseMetadata.StartLine // 0)\t\(.Title)\t\(.Message | gsub("\n"; " "))\t\($t)"' "${files[@]}" \
  | while IFS=$'\t' read -r sev id line title message target; do
      case "${sev}" in CRITICAL|HIGH) kind=warning ;; *) kind=notice ;; esac
      if [ -f "${target}" ]; then
        echo "::${kind} file=${target},line=${line},title=trivy ${sev} ${id}::${title}: ${message:0:250}"
      else
        echo "::${kind} title=trivy ${sev} ${id}::${title}: ${message:0:250} in ${target}"
      fi
    done
# Vulnerabilities in referenced images: job-level (no source line).
jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
  | "\(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion // "no fix")\t\($t)"' "${files[@]}" \
  | while IFS=$'\t' read -r sev id pkg inst fix target; do
      case "${sev}" in CRITICAL|HIGH) kind=warning ;; *) kind=notice ;; esac
      echo "::${kind} title=trivy ${sev} ${id}::${pkg} ${inst} (fixed: ${fix}) in image ${target}"
    done
jq -r '.Results[]? | .Target as $t | .Secrets[]?
  | "\($t)\t\(.RuleID)\t\(.Title)\t\(.StartLine // 0)"' "${files[@]}" \
  | while IFS=$'\t' read -r target rule title line; do
      if [ -f "${target}" ]; then echo "::error file=${target},line=${line},title=trivy secret ${rule}::${title}"
      else echo "::error title=trivy secret ${rule}::${title} in ${target}:${line}"; fi
    done

{
  echo "## Trivy Helm / Kustomize scan"
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
  echo "Misconfigurations: ${MISCONF}; image vulnerabilities: ${VULNS}; result files: ${#files[@]}. Gate: \`fail-on-severity: ${FAIL_ON}\`; highest: \`${MAX}\`."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "critical-count=${CRIT}"
  echo "high-count=${HIGH}"
  echo "medium-count=${MED}"
  echo "low-count=${LOW}"
  echo "secret-count=${SECRETS}"
  echo "max-severity=${MAX}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "trivy: critical ${CRIT}, high ${HIGH}, medium ${MED}, low ${LOW}, unknown ${UNK}, secrets ${SECRETS} (misconfig ${MISCONF}, vulns ${VULNS}); threshold '${FAIL_ON}'"

if [ "${FAIL_ON}" != "none" ] && [ "${SECRETS}" -gt 0 ]; then
  echo "::error title=trivy::${SECRETS} secret(s) found in chart or overlay sources."
  exit 1
fi
BLOCKED=$(jq -n --argjson b "${BLOCK}" '[inputs | .Results[]? | (.Misconfigurations[]? | select(.Status == "FAIL")), .Vulnerabilities[]? | select(.Severity as $s | $b | index($s))] | length' "${files[@]}")
if [ "${BLOCKED}" -gt 0 ]; then
  echo "::error title=trivy::${BLOCKED} finding(s) at or above '${FAIL_ON}' severity."
  exit 1
fi
