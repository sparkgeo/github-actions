#!/usr/bin/env bash
# checkov gate. Inputs via env: RESULTS_JSON (checkov -o json output),
# FAIL_ON (critical|high|medium|low|none), DIRECTORY (scanned dir, for
# annotation paths). Writes failed-count and passed-count to GITHUB_OUTPUT.
#
# checkov only attaches severities when run with a Prisma Cloud API key; the
# community CLI reports every failed check with severity null. Per
# docs/gate-policy.md every checkov finding therefore counts as `high`:
# high|medium|low fail on any finding, critical and none never fail.
set -euo pipefail

case "${FAIL_ON}" in
  critical|none) BLOCKING=false ;;
  high|medium|moderate|low) BLOCKING=true ;;
  *) echo "::error title=checkov::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

# checkov emits one object per framework when several ran, else one object.
ROWS="$(jq -r 'if type=="array" then .[] else . end
  | .results.failed_checks[]?
  | "\(.file_path)\t\(.file_line_range[0] // 1)\t\(.check_id)\t\(.resource)\t\(.check_name // "")"' "${RESULTS_JSON}")"
FAILED="$(jq '[if type=="array" then .[] else . end | .summary.failed] | add // 0' "${RESULTS_JSON}")"
PASSED="$(jq '[if type=="array" then .[] else . end | .summary.passed] | add // 0' "${RESULTS_JSON}")"
SKIPPED="$(jq '[if type=="array" then .[] else . end | .summary.skipped] | add // 0' "${RESULTS_JSON}")"

while IFS=$'\t' read -r file line check resource name; do
  [ -n "${file:-}" ] || continue
  # checkov paths are relative to --directory with a leading slash.
  echo "::warning file=${DIRECTORY%/}/${file#/},line=${line},title=checkov ${check}::${resource}: ${name}"
done <<< "${ROWS}"

{
  echo "failed-count=${FAILED}"
  echo "passed-count=${PASSED}"
  echo "skipped-count=${SKIPPED}"
} >> "${GITHUB_OUTPUT}"
echo "checkov: ${FAILED} failed, ${PASSED} passed, ${SKIPPED} skipped; threshold '${FAIL_ON}'"

if [ "${FAIL_ON}" = "critical" ] && [ "${FAILED}" -gt 0 ]; then
  echo "::notice title=checkov::findings count as high without a Prisma Cloud API key, so fail-on-severity=critical never blocks; use high to enforce"
fi
if [ "${BLOCKING}" = "true" ] && [ "${FAILED}" -gt 0 ]; then
  echo "::error title=checkov::${FAILED} failed check(s) at or above '${FAIL_ON}' severity."
  exit 1
fi
