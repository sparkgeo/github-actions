#!/usr/bin/env bash
# Checks the retention composite's check.py against hand-built OpenTofu plan
# JSON (passing and failing) and a CDK synth template with its manifest: every
# SPK_RET_* and SPK_RES_1 policy, the missing-entry case, the fail-on levels
# and the summary rows. Needs python3 with PyYAML (RETENTION_PYTHON; a venv
# is created here when unset) and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${ROOT}/.github/actions/retention/check.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${RETENTION_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "pyyaml==6.0.3"
  RETENTION_PYTHON="${TMP}/env/bin/python"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    "${RETENTION_PYTHON}" -I "${CHECK}" --output "${TMP}/$1.json" --comment "${TMP}/$1.md" "${@:2}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
policies() { jq -r '[.findings[].policy] | sort | unique | join(",")' "${TMP}/$1.json"; }
status() { jq -r --arg s "$2" '.rows[] | select(.store == $s) | .status' "${TMP}/$1.json"; }

echo "== passing plan: every store matches, no findings"
run pass --retention "${FIX}/retention.yml" --plan-json "${FIX}/tofu/plan-pass.json"
[ "${rc}" -eq 0 ] || fail "pass rc ${rc}: $(cat "${TMP}/pass.log")"
[ "$(jq -r '.findings | length' "${TMP}/pass.json")" = "0" ] || fail "no findings expected: $(jq -c .findings "${TMP}/pass.json")"
[ "$(jq -r '[.rows[].status] | unique | join(",")' "${TMP}/pass.json")" = "ok" ] || fail "all rows ok"
grep -q "^## Retention check: 5 store(s) declared, 5 row(s), 0 finding(s), 0 failing (fail-on: mismatch)" "${TMP}/pass.summary" || fail "summary: $(head -1 "${TMP}/pass.summary")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| `aws_s3_bucket.ingest` | 90d | lifecycle | 90 | ok |' "${TMP}/pass.summary" || fail "row: $(grep ingest "${TMP}/pass.summary" | head -1)"
head -1 "${TMP}/pass.md" | grep -q '^<!-- retention-check -->$' || fail "comment marker"

echo "== failing plan: lifecycle 365, log group never expires, RDS 7, TTL off, backup 400d and copied to eu-west-1, an unlisted restricted bucket in us-east-1"
run fail --retention "${FIX}/retention.yml" --plan-json "${FIX}/tofu/plan-fail.json"
[ "${rc}" -eq 1 ] || fail "fail rc ${rc}"
[ "$(policies fail)" = "SPK_RES_1,SPK_RET_1,SPK_RET_2,SPK_RET_3,SPK_RET_4,SPK_RET_5,SPK_RET_6" ] || fail "policies: $(policies fail)"
grep -q '^::error title=SPK_RET_2::aws_s3_bucket.ingest: lifecycle expiration 365 days, declared 90' "${TMP}/fail.log" || fail "SPK_RET_2"
grep -q '^::error title=SPK_RET_3::aws_cloudwatch_log_group.api: retention_in_days is 0 or absent (never expires)' "${TMP}/fail.log" || fail "SPK_RET_3"
grep -q '^::error title=SPK_RET_4::aws_rds_cluster.app: backup_retention_period 7, declared 35' "${TMP}/fail.log" || fail "SPK_RET_4"
grep -q '^::error title=SPK_RET_5::aws_dynamodb_table.sessions: TTL is not enabled' "${TMP}/fail.log" || fail "SPK_RET_5"
grep -q '^::error title=SPK_RET_6::aws_backup_plan.daily: rule daily keeps backups 400 days; longest declared retention 90d plus grace 35d' "${TMP}/fail.log" || fail "SPK_RET_6"
grep -q '^::error title=SPK_RET_1::aws_s3_bucket.exports: tagged data-class restricted but has no entry' "${TMP}/fail.log" || fail "SPK_RET_1 missing entry"
grep -q '^::warning title=SPK_RES_1::aws_s3_bucket.exports: created in us-east-1, allowed ca-central-1, us-west-2' "${TMP}/fail.log" || fail "SPK_RES_1 region (advisory at mismatch)"
grep -q '^::warning title=SPK_RES_1::aws_backup_plan.daily: rule daily copies backups to eu-west-1' "${TMP}/fail.log" || fail "SPK_RES_1 backup copy"
[ "$(status fail aws_s3_bucket.exports)" = "missing" ] || fail "missing row status"
[ "$(grep '^error-count=' "${TMP}/fail.out" | cut -d= -f2)" = "6" ] || fail "error-count: $(cat "${TMP}/fail.out")"

echo "== fail-on all also fails residency; fail-on none fails nothing"
run all --retention "${FIX}/retention.yml" --plan-json "${FIX}/tofu/plan-fail.json" --fail-on all
[ "$(grep '^error-count=' "${TMP}/all.out" | cut -d= -f2)" = "8" ] || fail "all error-count: $(cat "${TMP}/all.out")"
run none --retention "${FIX}/retention.yml" --plan-json "${FIX}/tofu/plan-fail.json" --fail-on none
[ "${rc}" -eq 0 ] || fail "none rc ${rc}"
[ "$(grep -c "^::warning" "${TMP}/none.log")" = "8" ] || fail "eight warnings at none"

echo "== store declared but not in the plan; residency override per store"
printf 'version: 1\ndefaults: {allowed_regions: [us-west-2]}\nstores:\n  aws_s3_bucket.gone: {retention: 30d, mechanism: lifecycle}\n  aws_rds_cluster.app: {retention: 35d, mechanism: backup_retention, residency: [ca-central-1]}\n' > "${TMP}/r2.yml"
run gone --retention "${TMP}/r2.yml" --plan-json "${FIX}/tofu/plan-pass.json" --fail-on all
grep -q '^::error title=SPK_RET_1::aws_s3_bucket.gone: declared in retention.yml but not in the plan' "${TMP}/gone.log" || fail "not in plan"
grep -q 'SPK_RES_1::aws_s3_bucket.ingest: created in ca-central-1, allowed us-west-2' "${TMP}/gone.log" || fail "default regions apply to the bucket"
grep -q 'SPK_RES_1::aws_rds_cluster.app' "${TMP}/gone.log" && fail "per-store residency must override the defaults"

echo "== CDK template with manifest region: passes; without manifest or region the region is unknown"
run cdk --retention "${FIX}/cdk/retention.yml" --template "${FIX}/cdk/Prod.template.json" --manifest "${FIX}/cdk/manifest.json"
[ "${rc}" -eq 0 ] || fail "cdk rc ${rc}: $(cat "${TMP}/cdk.log")"
[ "$(jq -r '.findings | length' "${TMP}/cdk.json")" = "0" ] || fail "cdk findings: $(jq -c .findings "${TMP}/cdk.json")"
[ "$(status cdk IngestBucket1A2B3C)" = "ok" ] || fail "cdk bucket row"
run cdk2 --retention "${FIX}/cdk/retention.yml" --template "${FIX}/cdk/Prod.template.json" --fail-on all
grep -q 'SPK_RES_1::IngestBucket1A2B3C: region unknown' "${TMP}/cdk2.log" || fail "unknown region note"
jq '.Resources.ApiLogs2B3C4D.Properties.RetentionInDays = 7 | .Resources.Sessions4D5E6F.Properties.TimeToLiveSpecification.AttributeName = "ttl"' "${FIX}/cdk/Prod.template.json" > "${TMP}/bad.template.json"
run cdk3 --retention "${FIX}/cdk/retention.yml" --template "${TMP}/bad.template.json" --region ca-central-1
[ "$(policies cdk3)" = "SPK_RET_3,SPK_RET_5" ] || fail "cdk policies: $(policies cdk3)"
grep -q 'SPK_RET_5::Sessions4D5E6F: TTL attribute ttl, declared expires_at' "${TMP}/cdk3.log" || fail "cdk ttl attribute"

echo "== missing retention.yml"
run nofile --retention "${TMP}/nope.yml" --plan-json "${FIX}/tofu/plan-pass.json"
{ [ "${rc}" -eq 1 ] && grep -q 'does not exist; copy docs/examples/retention.yml' "${TMP}/nofile.log"; } || fail "missing file"

echo "all retention checks passed"
