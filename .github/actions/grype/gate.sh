#!/usr/bin/env bash
# Gate on grype JSON results.
#
# Env: RESULTS (grype -o json file), FAIL_ON_SEVERITY
# (negligible|low|medium|high|critical), optional VEX (the OpenVEX document
# grype was given; matches it suppressed are listed, and statements that
# match nothing grype reports are flagged stale). Matches at or above the threshold
# become ::error annotations and fail the step (exit 1); the rest become
# ::warning annotations. Exit 2 on bad input.
# Outputs: match-count, blocking-count, vex-suppressed-count, vex-stale-count.
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

SUPPRESSED=0
STALE=0
if [ -n "${VEX:-}" ]; then
  while IFS=$'\t' read -r id sev pkg ver; do
    SUPPRESSED=$((SUPPRESSED + 1))
    echo "::notice title=grype::${id} ${sev} ${pkg} ${ver}: not affected per VEX"
  done < <(jq -r '.ignoredMatches[]? | select(any(.appliedIgnoreRules[]?; .namespace == "vex"))
    | [.vulnerability.id, .vulnerability.severity, .artifact.name, .artifact.version] | @tsv' "${RESULTS}")
  # A statement is stale when neither its name nor an alias is among the IDs grype matched.
  while IFS= read -r name; do
    STALE=$((STALE + 1))
    echo "::warning title=grype::VEX statement ${name} matches no finding grype reports; it is stale (remove it, or fix its product purl or aliases)"
  done < <(jq -r --slurpfile r "${RESULTS}" '
    ([$r[0].ignoredMatches[]?, $r[0].matches[]? | .vulnerability.id, .relatedVulnerabilities[]?.id]) as $seen
    | .statements[] | select(([.vulnerability.name] + (.vulnerability.aliases // [])) | any(. as $i | $seen | index($i)) | not)
    | .vulnerability.name' "${VEX}")
  {
    echo
    echo "VEX: ${SUPPRESSED} match(es) not affected per VEX; ${STALE} stale statement(s)."
  } >> "${GITHUB_STEP_SUMMARY}"
fi

{
  echo "match-count=${MATCHES}"
  echo "blocking-count=${BLOCKING}"
  echo "vex-suppressed-count=${SUPPRESSED}"
  echo "vex-stale-count=${STALE}"
} >> "${GITHUB_OUTPUT}"

[ "${BLOCKING}" -eq 0 ]
