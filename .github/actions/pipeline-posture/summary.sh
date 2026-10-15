#!/usr/bin/env bash
# Summarise a poutine SARIF file and apply fail-on (issue #234).
# Usage: summary.sh <poutine.sarif> <fail-on: error|warning|note|none>
# Prints error-count, warning-count, note-count and blocking-count for
# GITHUB_OUTPUT; appends a per-rule table to GITHUB_STEP_SUMMARY (stderr when
# unset). Exits 1 when a finding is at or above fail-on.
set -euo pipefail
SARIF="$1"
FAIL_ON="$2"
case "${FAIL_ON}" in error|warning|note|none) ;; *) echo "::error title=pipeline-posture::fail-on must be error, warning, note or none" >&2; exit 1 ;; esac
jq -e '.version == "2.1.0" and (.runs | type == "array")' "${SARIF}" > /dev/null \
  || { echo "::error title=pipeline-posture::${SARIF} is not SARIF 2.1.0" >&2; exit 1; }

# poutine rule -> zizmor audit that covers the same flaw in the PR gate (#25),
# so a weekly finding already blocked at PR time is not ticketed twice.
ZIZMOR='{"injection":"template-injection","untrusted_checkout_exec":"dangerous-triggers","default_permissions_on_risky_events":"excessive-permissions","if_always_true":"unsound-condition","job_all_secrets":"overprovisioned-secrets","known_vulnerability_in_build_component":"known-vulnerable-actions","pr_runs_on_self_hosted":"self-hosted-runner","confused_deputy_auto_merge":"bot-conditions","unpinnable_action":"unpinned-uses"}'
summary="$(jq -r --argjson z "${ZIZMOR}" '
  [.runs[].results[] | {rule: .ruleId, level: (.level // "warning")}]
  | group_by(.rule)
  | (["| poutine rule | Findings | Highest level | Also caught by zizmor |", "|---|---|---|---|"]
     + map("| `\(.[0].rule)` | \(length) | \(map(.level) | if index("error") then "error" elif index("warning") then "warning" else "note" end) | \($z[.[0].rule] // "-") |"))
  | join("\n")' "${SARIF}")"
{
  echo "### Pipeline posture (poutine, fail-on: ${FAIL_ON})"
  echo
  echo "${summary}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"

blocking=0
for level in error warning note; do
  n="$(jq --arg l "${level}" '[.runs[].results[] | select((.level // "warning") == $l)] | length' "${SARIF}")"
  echo "${level}-count=${n}"
  # Levels are ordered error > warning > note; count everything at or above fail-on.
  if [ "${FAIL_ON}" != "none" ]; then blocking=$((blocking + n)); fi
  if [ "${level}" = "${FAIL_ON}" ]; then FAIL_ON=none; fi
done
echo "blocking-count=${blocking}"
[ "${blocking}" = "0" ]
