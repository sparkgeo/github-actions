#!/usr/bin/env bash
# Checks the serverless policy pack with a real checkov run over the pass and
# fail fixtures (Terraform and CloudFormation), serverless-roles.py over the
# templates, and, when trivy is on PATH, the package scan over the fixture
# requirements. Tool paths via CHECKOV and TRIVY.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
POLICIES="${ROOT}/policies/serverless"
ROLES="${ROOT}/.github/actions/checkov/serverless-roles.py"
CHECKOV="${CHECKOV:-checkov}"
TRIVY="${TRIVY:-trivy}"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

CHECKS="$(grep -oE '^[A-Z_0-9]+' "${POLICIES}/checks.txt" | paste -sd, -)"
[ -n "${CHECKS}" ] || fail "checks.txt parsed to nothing"
CUSTOM="$(grep -hoE 'id: "SPK_SLS_[0-9]+"' "${POLICIES}"/*.yaml | grep -oE 'SPK_SLS_[0-9]+' | paste -sd, -)"
[ "${CUSTOM}" = "SPK_SLS_1,SPK_SLS_3" ] || fail "custom policy ids: ${CUSTOM}"

scan() {  # <framework> <fixture> -> $TMP/<framework>-<fixture>.json
  "${CHECKOV}" -d "${FIX}/$1/$2" --framework "$1" --external-checks-dir "${POLICIES}" \
    --check "${CHECKS},${CUSTOM}" -o json > "${TMP}/$1-$2.json" 2>/dev/null || true
  [ -s "${TMP}/$1-$2.json" ] || fail "checkov produced no JSON for $1/$2"
}
failed_set() { jq -r '[.results.failed_checks[]? | "\(.check_id) \(.resource)"] | sort | join("\n")' "${TMP}/$1.json"; }

echo "== terraform pass: zero findings"
scan terraform pass
[ -z "$(failed_set terraform-pass)" ] || fail "terraform pass has findings:
$(failed_set terraform-pass)"
[ "$(jq '[.results.passed_checks[]? | select(.check_id | startswith("SPK_SLS"))] | length' "${TMP}/terraform-pass.json")" = "2" ] || fail "both graph policies must evaluate on the pass fixture"

echo "== terraform fail: role from a literal ARN, no log group wiring, wildcard policy, no DLQ"
scan terraform fail
expected="$(cat <<'EOT'
CKV_AWS_115 aws_lambda_function.export
CKV_AWS_116 aws_lambda_function.export
CKV_AWS_173 aws_lambda_function.export
CKV_AWS_288 aws_iam_role_policy.shared
CKV_AWS_289 aws_iam_role_policy.shared
CKV_AWS_290 aws_iam_role_policy.shared
CKV_AWS_355 aws_iam_role_policy.shared
CKV_AWS_45 aws_lambda_function.export
CKV_AWS_66 aws_cloudwatch_log_group.export
SPK_SLS_1 aws_lambda_function.export
SPK_SLS_3 aws_lambda_function.export
EOT
)"
actual="$(failed_set terraform-fail)"
[ "${actual}" = "${expected}" ] || fail "terraform fail findings differ:
${actual}"

echo "== cloudformation pass: zero findings"
scan cloudformation pass
[ -z "$(failed_set cloudformation-pass)" ] || fail "cloudformation pass has findings:
$(failed_set cloudformation-pass)"

echo "== cloudformation fail: shared role passes the graph policy (the script catches it), orphan ARN fails it"
scan cloudformation fail
[ "$(jq -r '[.results.failed_checks[]? | select(.check_id == "SPK_SLS_1") | .resource] | join(",")' "${TMP}/cloudformation-fail.json")" = "AWS::Lambda::Function.OrphanFunction" ] || fail "SPK_SLS_1 on cloudformation"
[ "$(jq -r '[.results.failed_checks[]? | select(.check_id == "SPK_SLS_3") | .resource] | sort | join(",")' "${TMP}/cloudformation-fail.json")" = "AWS::Lambda::Function.ExportFunction,AWS::Lambda::Function.OrphanFunction,AWS::Lambda::Function.ReportFunction" ] || fail "SPK_SLS_3 on cloudformation"
[ "$(jq -r '[.results.failed_checks[]? | select(.check_id == "CKV_AWS_111") | .resource] | join(",")' "${TMP}/cloudformation-fail.json")" = "AWS::IAM::Role.SharedRole" ] || fail "wildcard write on the shared role"
[ "$(jq '[.results.failed_checks[]? | select(.check_id == "CKV_AWS_116")] | length' "${TMP}/cloudformation-fail.json")" = "3" ] || fail "DLQ check on all three functions"

echo "== serverless-roles.py: shared role across functions"
set +e; python3 -I "${ROLES}" --template "${FIX}/cloudformation/fail" --fail > "${TMP}/roles.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "roles fail rc ${rc}: $(cat "${TMP}/roles.log")"
grep -q '^::error file=.*/cloudformation/fail/template.json,title=serverless-roles SPK_SLS_1::role SharedRole is shared by 2 functions (ExportFunction, ReportFunction)' "${TMP}/roles.log" || fail "shared role annotation: $(cat "${TMP}/roles.log")"
grep -q '^serverless-roles: 3 functions, 1 shared role(s), 0 YAML template(s) skipped' "${TMP}/roles.log" || fail "roles summary"
python3 -I "${ROLES}" --template "${FIX}/cloudformation/pass/template.json" --fail > "${TMP}/roles-pass.log" 2>&1 || fail "roles pass: $(cat "${TMP}/roles-pass.log")"
printf 'Resources:\n  Fn:\n    Type: AWS::Lambda::Function\n' > "${TMP}/template.yaml"
python3 -I "${ROLES}" --template "${TMP}/template.yaml" --fail > "${TMP}/roles-yaml.log" 2>&1 || fail "yaml template must not fail"
grep -q '^::notice file=.*template.yaml,title=serverless-roles::YAML template skipped' "${TMP}/roles-yaml.log" || fail "yaml notice"
set +e; python3 -I "${ROLES}" --template "${FIX}/cloudformation/fail" > "${TMP}/roles-nofail.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "without --fail the script reports only"

if command -v "${TRIVY}" > /dev/null; then
  echo "== package scan: the fixture requirements carry known CVEs"
  "${TRIVY}" fs --scanners vuln -f json -q "${FIX}/package" > "${TMP}/trivy.json" 2>/dev/null || fail "trivy run"
  [ "$(jq '[.Results[]?.Vulnerabilities[]?] | length' "${TMP}/trivy.json")" -ge 1 ] || fail "trivy found nothing in the package fixture"
else
  echo "trivy not on PATH; package scan skipped (ci.yml runs it)"
fi

echo "all serverless-scan checks passed"
