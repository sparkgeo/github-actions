#!/usr/bin/env bash
# Pipeline posture (issue #234): poutine on the fixture repository must report
# the PR-title injection and the pull_request_target checkout of the PR head;
# summary.sh must accept the SARIF and apply fail-on by level.
# Usage: tests/poutine/run.sh <poutine binary>
set -euo pipefail
POUTINE="${1:?usage: run.sh <poutine binary>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY="${HERE}/../../.github/actions/pipeline-posture/summary.sh"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }

( cd "${HERE}/fixtures/repo" && "${POUTINE}" analyze_local . --format sarif --quiet --disable-version-check ) > "${WORK}/out.sarif"
check "both flaws reported" \
  "$(jq -r '[.runs[].results[] | "\(.ruleId):\(.level):\(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine)"] | sort | join(" ")' "${WORK}/out.sarif")" \
  "injection:warning:.github/workflows/vulnerable.yml:21 untrusted_checkout_exec:error:.github/workflows/vulnerable.yml:22"

export GITHUB_STEP_SUMMARY="${WORK}/summary.md"
status=0; bash "${SUMMARY}" "${WORK}/out.sarif" none > "${WORK}/counts" || status=$?
check "fail-on none reports only" "$(tr '\n' ' ' < "${WORK}/counts")${status}" "error-count=1 warning-count=1 note-count=0 blocking-count=0 0"
check "summary names the zizmor audit" "$(grep -c 'template-injection' "${WORK}/summary.md")" "1"
status=0; bash "${SUMMARY}" "${WORK}/out.sarif" error > "${WORK}/counts" || status=$?
check "fail-on error counts only errors" "$(grep blocking "${WORK}/counts")/${status}" "blocking-count=1/1"
status=0; bash "${SUMMARY}" "${WORK}/out.sarif" warning > "${WORK}/counts" || status=$?
check "fail-on warning counts errors and warnings" "$(grep blocking "${WORK}/counts")/${status}" "blocking-count=2/1"
echo '{"version": "2.0.0"}' > "${WORK}/bad.sarif"
status=0; bash "${SUMMARY}" "${WORK}/bad.sarif" none > /dev/null 2>&1 || status=$?
check "non-SARIF input is rejected" "${status}" "1"

exit "${fail}"
