#!/usr/bin/env bash
# Gate on grype JSON results.
#
# Env: RESULTS (grype -o json file), FAIL_ON_SEVERITY
# (negligible|low|medium|high|critical). Matches at or above the threshold
# become ::error annotations and fail the step (exit 1); the rest become
# ::warning annotations. Exit 2 on bad input.
# Outputs: match-count, blocking-count.
set -euo pipefail

: "${RESULTS:?}" "${FAIL_ON_SEVERITY:?}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Severity rank. grype also emits "Unknown" for advisories with no score;
# ranked below negligible so it never blocks on its own.
rank() {
  case "$1" in
    Critical|critical) echo 4 ;;
    High|high)         echo 3 ;;
    Medium|medium)     echo 2 ;;
    Low|low)           echo 1 ;;
    Negligible|negligible) echo 0 ;;
    *) echo -1 ;;
  esac
}

THRESHOLD="$(rank "${FAIL_ON_SEVERITY}")"
if [ "${THRESHOLD}" -lt 0 ]; then
  echo "::error title=grype::fail-on-severity '${FAIL_ON_SEVERITY}' is not one of negligible, low, medium, high, critical"
  exit 2
fi
if [ ! -f "${RESULTS}" ]; then
  echo "::error title=grype::results file not found: ${RESULTS}"
  exit 2
fi

MATCHES=0
BLOCKING=0
declare -A TOTAL=() BLOCK=()
while IFS=$'\t' read -r id sev pkg ver fixstate fixver; do
  MATCHES=$((MATCHES + 1))
  TOTAL["${sev}"]=$(( ${TOTAL["${sev}"]:-0} + 1 ))
  case "${fixstate}" in
    fixed) fix="fixed in ${fixver}" ;;
    *)     fix="${fixstate:-no fix}" ;;
  esac
  msg="${id} ${sev} ${pkg} ${ver} (${fix})"
  if [ "$(rank "${sev}")" -ge "${THRESHOLD}" ]; then
    BLOCKING=$((BLOCKING + 1))
    BLOCK["${sev}"]=$(( ${BLOCK["${sev}"]:-0} + 1 ))
    echo "::error title=grype::${msg}"
  else
    echo "::warning title=grype::${msg}"
  fi
done < <(jq -r '.matches[] | [.vulnerability.id, .vulnerability.severity, .artifact.name, .artifact.version, .vulnerability.fix.state, (.vulnerability.fix.versions | join(","))] | @tsv' "${RESULTS}")

{
  echo "### SBOM scan (grype)"
  echo
  echo "Threshold: \`${FAIL_ON_SEVERITY}\`"
  echo
  if [ "${MATCHES}" -eq 0 ]; then
    echo "No vulnerabilities matched."
  else
    echo "| Severity | Matches | Blocking |"
    echo "|----------|---------|----------|"
    for sev in Critical High Medium Low Negligible Unknown; do
      n="${TOTAL[${sev}]:-0}"
      [ "${n}" -gt 0 ] || continue
      echo "| ${sev} | ${n} | ${BLOCK[${sev}]:-0} |"
    done
  fi
} >> "${GITHUB_STEP_SUMMARY}"

{
  echo "match-count=${MATCHES}"
  echo "blocking-count=${BLOCKING}"
} >> "${GITHUB_OUTPUT}"

[ "${BLOCKING}" -eq 0 ]
