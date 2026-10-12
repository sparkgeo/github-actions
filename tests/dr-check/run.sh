#!/usr/bin/env bash
# Checks the DR policy pack with a real checkov run over the pass and fail
# fixtures, then report.py over the failing run's JSON. Tool path via CHECKOV.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
POLICIES="${ROOT}/policies/dr"
REPORT="${ROOT}/.github/actions/checkov/dr-report.py"
CHECKOV="${CHECKOV:-checkov}"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

CHECKS="$(grep -oE '^[A-Z_0-9]+' "${POLICIES}/checks.txt" | paste -sd, -)"
[ -n "${CHECKS}" ] || fail "checks.txt parsed to nothing"

scan() {  # <fixture> -> $TMP/<fixture>.json
  "${CHECKOV}" -d "${FIX}/$1" --framework terraform --external-checks-dir "${POLICIES}" \
    --check "${CHECKS},SPK_DR_1,SPK_DR_2,SPK_DR_3,SPK_DR_4" -o json > "${TMP}/$1.json" 2>/dev/null || true
  [ -s "${TMP}/$1.json" ] || fail "checkov produced no JSON for $1"
}
failed_set() { jq -r '[.results.failed_checks[]? | "\(.check_id) \(.resource)"] | sort | join("\n")' "${TMP}/$1.json"; }

echo "== pass fixture: zero findings"
scan pass
[ -z "$(failed_set pass)" ] || fail "pass fixture has findings:
$(failed_set pass)"

echo "== fail fixture: one finding per control"
scan fail
expected="$(cat <<'EOT'
CKV_AWS_133 aws_db_instance.main
CKV_AWS_134 aws_elasticache_cluster.cache
CKV_AWS_144 aws_s3_bucket.data
CKV_AWS_157 aws_db_instance.main
CKV_AWS_166 aws_backup_vault.main
CKV_AWS_21 aws_s3_bucket.data
CKV_AWS_28 aws_dynamodb_table.sessions
SPK_DR_1 aws_db_instance.main
SPK_DR_2 aws_efs_file_system.shared
SPK_DR_3 aws_dynamodb_table.sessions
SPK_DR_4 aws_backup_plan.main
EOT
)"
actual="$(failed_set fail)"
[ "${actual}" = "${expected}" ] || fail "fail fixture findings differ:
${actual}"
[ "$(jq -r '[.results.skipped_checks[]? | .check_id] | sort | join(",")' "${TMP}/fail.json")" = "CKV_AWS_144,CKV_AWS_21" ] || fail "skips recorded: $(jq -c '.results.skipped_checks' "${TMP}/fail.json")"

echo "== dr-report.py: grouped comment, remediation, suppressions without a reason"
run_report() {  # <json> [args]
  local dir="${TMP}/report"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${REPORT}" --json "$1" --report "${dir}/report.md" "${@:2}" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
run_report "${TMP}/fail.json" --directory stacks/prod
[ "${rc}" -eq 0 ] || fail "report rc ${rc}: $(cat "${TMP}/report/log")"
out() { grep "^$1=" "${TMP}/report/out" | cut -d= -f2-; }
[ "$(out failed-count)" = "11" ] || fail "failed-count $(out failed-count)"
[ "$(out resource-count)" = "7" ] || fail "resource-count $(out resource-count)"
[ "$(out unreasoned-skips)" = "1" ] || fail "unreasoned-skips $(out unreasoned-skips)"
grep -q '^<!-- dr-check -->' "${TMP}/report/report.md" || fail "marker"
grep -q '^## DR readiness (stacks/prod): 11 findings on 7 resources' "${TMP}/report/report.md" || fail "heading: $(head -2 "${TMP}/report/report.md")"
grep -qF "### \`aws_db_instance.main\`" "${TMP}/report/report.md" || fail "grouped by resource"
grep -qF "\`CKV_AWS_157\`" "${TMP}/report/report.md" || fail "check id listed"
grep -qF 'multi_az = true' "${TMP}/report/report.md" || fail "remediation snippet"
grep -qF 'https://docs.prismacloud.io' "${TMP}/report/report.md" || fail "guideline link from checkov"
grep -qF 'docs/dr-checklist.md' "${TMP}/report/report.md" || fail "custom policy guideline"
grep -q '^### Suppressions without a reason' "${TMP}/report/report.md" || fail "suppression section"
grep -qF "\`CKV_AWS_21\` on \`aws_s3_bucket.logs\`" "${TMP}/report/report.md" || fail "unreasoned skip listed: $(grep -A3 'Suppressions' "${TMP}/report/report.md")"
! grep -qF "CKV_AWS_144\` on \`aws_s3_bucket.logs" "${TMP}/report/report.md" || fail "reasoned skip must not be listed"
grep -q 'DR readiness' "${TMP}/report/summary" || fail "step summary"
grep -q '^::warning title=dr-check::aws_s3_bucket.logs skips CKV_AWS_21 without a reason' "${TMP}/report/log" || fail "skip warning: $(cat "${TMP}/report/log")"

run_report "${TMP}/pass.json"
[ "${rc}" -eq 0 ] || fail "clean report rc ${rc}"
grep -q '^## DR readiness: no findings' "${TMP}/report/report.md" || fail "clean heading: $(head -2 "${TMP}/report/report.md")"

echo "all dr-check checks passed"
