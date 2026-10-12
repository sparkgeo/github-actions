#!/usr/bin/env bash
# Checks every tagging-standard enforcement point against pass and fail
# fixtures: tflint (aws, azurerm rulesets), checkov (SPK_TAG_1 aws,
# SPK_TAG_2 google), conftest (tags.rego) and the CDK aspect (when
# aws-cdk-lib is importable). Tool paths via TFLINT, CHECKOV, CONFTEST,
# CDK_PYTHON; tflint --init downloads the rulesets from GitHub.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
FIX="${HERE}/fixtures"
TAGS="${ROOT}/policies/tags"
POLICIES="${ROOT}/.github/actions/k8s-policy/policies"
TFLINT="${TFLINT:-tflint}"
CHECKOV="${CHECKOV:-checkov}"
CONFTEST="${CONFTEST:-conftest}"
CDK_PYTHON="${CDK_PYTHON:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in standard.yml tflint/aws.tflint.hcl tflint/azurerm.tflint.hcl checkov/spk_tag_1.yaml checkov/spk_tag_2.yaml; do
  [ -f "${TAGS}/${f}" ] || fail "missing ${TAGS}/${f}"
done
[ -f "${POLICIES}/tags.rego" ] || fail "missing ${POLICIES}/tags.rego"

echo "== tflint: aws ruleset, default_tags satisfy the rule"
tfl() {  # <provider> <fixture>; sets rc, writes $TMP/tflint.log
  local cfg="${TAGS}/tflint/$1.tflint.hcl"
  set +e
  ( cd "${FIX}/terraform/$2" && "${TFLINT}" --init --config "${cfg}" > /dev/null 2>&1 \
    && "${TFLINT}" --config "${cfg}" --only "$1_resource_missing_tags" --minimum-failure-severity=notice --format compact ) > "${TMP}/tflint.log" 2>&1
  rc=$?
  set -e
}
tfl aws aws-pass
[ "${rc}" -eq 0 ] || fail "tflint aws-pass rc ${rc}: $(cat "${TMP}/tflint.log")"
tfl aws aws-fail
[ "${rc}" -eq 2 ] || fail "tflint aws-fail rc ${rc}: $(cat "${TMP}/tflint.log")"
grep -qE 'main.tf:[0-9]+:[0-9]+: Notice - The resource is missing the following tags: "data-class", "environment", "project". \(aws_resource_missing_tags\)' "${TMP}/tflint.log" || fail "tflint aws-fail message: $(cat "${TMP}/tflint.log")"

echo "== tflint: azurerm ruleset"
tfl azurerm azurerm-pass
[ "${rc}" -eq 0 ] || fail "tflint azurerm-pass rc ${rc}: $(cat "${TMP}/tflint.log")"
tfl azurerm azurerm-fail
[ "${rc}" -eq 2 ] || fail "tflint azurerm-fail rc ${rc}: $(cat "${TMP}/tflint.log")"
grep -q 'missing the following tags: "data-class", "environment", "project"' "${TMP}/tflint.log" || fail "tflint azurerm-fail message: $(cat "${TMP}/tflint.log")"

echo "== checkov: SPK_TAG_1 (aws default_tags) and SPK_TAG_2 (google default_labels)"
ckv() {  # <fixture> <check>; prints "RESULT resource"
  "${CHECKOV}" -d "${FIX}/terraform/$1" --framework terraform --external-checks-dir "${TAGS}/checkov" \
    -c "$2" -o json 2>/dev/null \
    | jq -r --arg c "$2" '[.results.failed_checks[]?, .results.passed_checks[]?] | map(select(.check_id == $c) | "\(.check_result.result) \(.resource)") | join(";")'
}
[ "$(ckv aws-pass SPK_TAG_1)" = "PASSED aws.default" ] || fail "checkov aws-pass: $(ckv aws-pass SPK_TAG_1)"
[ "$(ckv aws-fail SPK_TAG_1)" = "FAILED aws.default" ] || fail "checkov aws-fail: $(ckv aws-fail SPK_TAG_1)"
[ "$(ckv google-pass SPK_TAG_2)" = "PASSED google.default" ] || fail "checkov google-pass: $(ckv google-pass SPK_TAG_2)"
[ "$(ckv google-fail SPK_TAG_2)" = "FAILED google.default" ] || fail "checkov google-fail: $(ckv google-fail SPK_TAG_2)"
[ -z "$(ckv aws-pass SPK_TAG_2)" ] || fail "SPK_TAG_2 must ignore aws providers"

echo "== conftest: tags.rego denies, enum and pattern checks, dormant without data"
cft() {  # <manifest> [args]; prints sorted deny msgs
  local m="$1"; shift
  "${CONFTEST}" test --all-namespaces -p "${POLICIES}" -o json --no-fail "$@" "${m}" | jq -r '.[] | .failures[]? | .msg' | sort
}
cft "${FIX}/manifests/untagged/resources.yaml" -d "${TAGS}/standard.yml" > "${TMP}/msgs"
cat > "${TMP}/want" <<'WANT'
Deployment/web: missing required label "data-class"
Deployment/web: missing required label "environment"
Deployment/web: missing required label "owner"
Deployment/web: missing required label "project"
Namespace/fixture: label environment="production" is not one of dev, staging, prod, shared
Namespace/fixture: label owner="bob" does not match ^(team-[a-z0-9-]+|[a-z.]+_at_sparkgeo\.com)$
Namespace/fixture: label project="Fixture_App" does not match ^[a-z0-9-]{3,40}$
WANT
diff -u "${TMP}/want" "${TMP}/msgs" || fail "untagged manifest: unexpected deny set"
cft "${FIX}/manifests/tagged/resources.yaml" -d "${TAGS}/standard.yml" > "${TMP}/msgs"
[ ! -s "${TMP}/msgs" ] || fail "tagged manifest produced denies: $(cat "${TMP}/msgs")"
cft "${FIX}/manifests/untagged/resources.yaml" > "${TMP}/msgs"
[ ! -s "${TMP}/msgs" ] || fail "tags policy must stay dormant without the standard loaded: $(cat "${TMP}/msgs")"

echo "== cdk: RequiredTagsAspect"
if "${CDK_PYTHON}" -c "import aws_cdk" 2>/dev/null; then
  "${CDK_PYTHON}" "${HERE}/cdk/check_aspect.py" || fail "cdk aspect check"
else
  echo "aws-cdk-lib not importable by ${CDK_PYTHON}; skipped (CI installs it)"
fi

echo "all tagging checks passed"
