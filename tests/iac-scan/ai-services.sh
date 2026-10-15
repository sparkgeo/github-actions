#!/usr/bin/env bash
# Checks the AI-service policy pack (issue #189) with a real checkov run over
# the pass and fail fixtures, then ai-logging.py (SPK_AI_1) over both. Tool
# path via CHECKOV. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
POLICIES="${ROOT}/policies/ai"
LOGGING="${ROOT}/.github/actions/checkov/ai-logging.py"
CHECKOV="${CHECKOV:-checkov}"
FIX="${HERE}/fixtures/ai"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

CHECKS="$(grep -oE '^[A-Z_0-9]+' "${POLICIES}/checks.txt" | paste -sd, -)"
[ -n "${CHECKS}" ] || fail "checks.txt parsed to nothing"
CUSTOM="$(grep -hoE 'id: "SPK_AI_[0-9]+"' "${POLICIES}"/*.yaml | grep -oE 'SPK_AI_[0-9]+' | paste -sd, -)"
[ "${CUSTOM}" = "SPK_AI_2,SPK_AI_3" ] || fail "custom policy ids: ${CUSTOM}"

scan() {  # <fixture> -> $TMP/<fixture>.json
  "${CHECKOV}" -d "${FIX}/$1" --framework terraform --external-checks-dir "${POLICIES}" \
    --check "${CHECKS},${CUSTOM}" -o json > "${TMP}/$1.json" 2>/dev/null || true
  [ -s "${TMP}/$1.json" ] || fail "checkov produced no JSON for $1"
}
failed_set() { jq -r '[.results.failed_checks[]? | "\(.check_id) \(.resource)"] | sort | join("\n")' "${TMP}/$1.json"; }

echo "== pass fixture: zero findings across Bedrock, SageMaker, Vertex AI and Azure OpenAI"
scan pass
[ -z "$(failed_set pass)" ] || fail "pass fixture has findings:
$(failed_set pass)"
[ "$(jq '[.results.passed_checks[]? | .check_id] | unique | length' "${TMP}/pass.json")" -ge 14 ] || fail "too few checks evaluated on the pass fixture: $(jq '[.results.passed_checks[]? | .check_id] | unique' "${TMP}/pass.json")"

echo "== fail fixture: one finding per control"
scan fail
expected="$(cat <<'EOT'
CKV2_AZURE_22 azurerm_cognitive_account.openai
CKV_AWS_122 aws_sagemaker_notebook_instance.n
CKV_AWS_187 aws_sagemaker_notebook_instance.n
CKV_AWS_22 aws_sagemaker_notebook_instance.n
CKV_AWS_306 aws_sagemaker_notebook_instance.n
CKV_AWS_307 aws_sagemaker_notebook_instance.n
CKV_AWS_371 aws_sagemaker_notebook_instance.n
CKV_AWS_373 aws_bedrockagent_agent.a
CKV_AWS_383 aws_bedrockagent_agent.a
CKV_AZURE_134 azurerm_cognitive_account.openai
CKV_AZURE_236 azurerm_cognitive_account.openai
CKV_AZURE_238 azurerm_cognitive_account.openai
CKV_AZURE_247 azurerm_cognitive_account.openai
SPK_AI_2 google_vertex_ai_endpoint.e
SPK_AI_3 azurerm_cognitive_account.openai
EOT
)"
actual="$(failed_set fail)"
[ "${actual}" = "${expected}" ] || fail "fail fixture findings differ:
${actual}"

echo "== ai-logging.py (SPK_AI_1): invocation logging declared with the Bedrock agent, or not"
python3 -I "${LOGGING}" --directory "${FIX}/pass" --fail > "${TMP}/log-pass" 2>&1 || fail "pass: $(cat "${TMP}/log-pass")"
grep -q '^ai-logging: 1 Bedrock resource(s), invocation logging declared' "${TMP}/log-pass" || fail "pass summary: $(cat "${TMP}/log-pass")"
set +e; python3 -I "${LOGGING}" --directory "${FIX}/fail" --fail > "${TMP}/log-fail" 2>&1; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "fail rc ${rc}: $(cat "${TMP}/log-fail")"
grep -q '^::error file=.*/ai/fail/main.tf,title=checkov SPK_AI_1::aws_bedrockagent_agent.a is declared but no aws_bedrock_model_invocation_logging_configuration is' "${TMP}/log-fail" || fail "error annotation: $(cat "${TMP}/log-fail")"
set +e; python3 -I "${LOGGING}" --directory "${FIX}/fail" > "${TMP}/log-nofail" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "without --fail the script reports only"
mkdir -p "${TMP}/cfn" && printf '{"Resources": {"A": {"Type": "AWS::Bedrock::Agent", "Properties": {}}}}\n' > "${TMP}/cfn/template.json"
python3 -I "${LOGGING}" --directory "${TMP}/cfn" --fail > "${TMP}/log-cfn" 2>&1 || fail "cloudformation must not fail"
grep -q '^::notice file=.*template.json,title=checkov SPK_AI_1::Bedrock resources in a CloudFormation template' "${TMP}/log-cfn" || fail "cloudformation notice"
mkdir -p "${TMP}/none" && printf 'resource "aws_s3_bucket" "b" {\n  bucket = "b"\n}\n' > "${TMP}/none/main.tf"
python3 -I "${LOGGING}" --directory "${TMP}/none" --fail > "${TMP}/log-none" 2>&1 || fail "no bedrock must pass"
grep -q '^ai-logging: 0 Bedrock resource(s)' "${TMP}/log-none" || fail "none summary"

echo "all ai-services checks passed"
