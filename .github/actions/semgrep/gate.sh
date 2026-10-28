#!/usr/bin/env bash
# semgrep gate. Inputs via env: RESULTS_JSON (semgrep --json-output),
# FAIL_ON (critical|high|medium|low|none). Writes per-severity counts and
# max-severity to GITHUB_OUTPUT, a summary to GITHUB_STEP_SUMMARY, and one
# inline annotation per finding. Mapping per docs/gate-policy.md: semgrep has
# three levels, ERROR -> high, WARNING -> medium, INFO -> low. `critical`
# therefore behaves like `high` (nothing in semgrep outranks ERROR); `none`
# never fails.
set -euo pipefail

case "${FAIL_ON}" in
  critical|high)   BLOCK='["ERROR"]' ;;
  medium|moderate) BLOCK='["ERROR","WARNING"]' ;;
  low)             BLOCK='["ERROR","WARNING","INFO"]' ;;
  none)            BLOCK='[]' ;;
  *) echo "::error title=semgrep::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

count() { jq --arg s "$1" '[.results[]? | select(.extra.severity == $s)] | length' "${RESULTS_JSON}"; }
ERR=$(count ERROR); WARN=$(count WARNING); INFO=$(count INFO)
PARSE_ERRORS=$(jq '[.errors[]?] | length' "${RESULTS_JSON}")
SCANNED=$(jq '[.paths.scanned[]?] | length' "${RESULTS_JSON}")

if   [ "${ERR}" -gt 0 ]; then MAX=high
elif [ "${WARN}" -gt 0 ]; then MAX=medium
elif [ "${INFO}" -gt 0 ]; then MAX=low
else MAX=none; fi

jq -r '.results[]? | "\(.extra.severity)\t\(.path)\t\(.start.line)\t\(.check_id)\t\(.extra.message | gsub("\n"; " "))"' "${RESULTS_JSON}" \
  | while IFS=$'\t' read -r sev path line check message; do
      case "${sev}" in ERROR) kind=error ;; WARNING) kind=warning ;; *) kind=notice ;; esac
      echo "::${kind} file=${path},line=${line},title=semgrep ${check##*.}::${message:0:300}"
    done

{
  echo "## Semgrep"
  echo
  echo "| Severity | Count |"
  echo "|---|---|"
  echo "| ERROR (high) | ${ERR} |"
  echo "| WARNING (medium) | ${WARN} |"
  echo "| INFO (low) | ${INFO} |"
  echo
  echo "Files scanned: ${SCANNED}; parse errors: ${PARSE_ERRORS}. Gate: \`fail-on-severity: ${FAIL_ON}\`; highest found: \`${MAX}\`."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "error-count=${ERR}"
  echo "warning-count=${WARN}"
  echo "info-count=${INFO}"
  echo "max-severity=${MAX}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "semgrep: ${ERR} error, ${WARN} warning, ${INFO} info finding(s) across ${SCANNED} file(s); threshold '${FAIL_ON}'"

if [ "${PARSE_ERRORS}" -gt 0 ]; then
  echo "::warning title=semgrep::${PARSE_ERRORS} file(s) could not be parsed and were skipped"
fi
BLOCKED=$(jq --argjson b "${BLOCK}" '[.results[]? | select(.extra.severity as $s | $b | index($s))] | length' "${RESULTS_JSON}")
if [ "${BLOCKED}" -gt 0 ]; then
  echo "::error title=semgrep::${BLOCKED} finding(s) at or above '${FAIL_ON}' severity."
  exit 1
fi
