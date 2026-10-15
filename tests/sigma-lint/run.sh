#!/usr/bin/env bash
# Checks the sigma-lint composite's check.py against the fixture rule set:
# one passing rule with a test case, one syntax error (id is not a UUID),
# one rule without a test case; plus malformed test cases, an orphan test
# case, the stale list, splunk conversion and the require-test-case switch.
# Needs a virtualenv with sigma-cli and the splunk backend (SIGMA_ENV, created
# when unset; PyPI access).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${ROOT}/.github/actions/sigma-lint/check.py"
FIX="${HERE}/fixtures"
SIGMA_CLI_VERSION="${SIGMA_CLI_VERSION:-3.1.0}"
SPLUNK_VERSION="${SPLUNK_VERSION:-2.1.0}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${SIGMA_ENV:-}" ]; then
  SIGMA_ENV="${TMP}/env"
  python3 -m venv "${SIGMA_ENV}"
  "${SIGMA_ENV}/bin/python" -m pip install --quiet --disable-pip-version-check "sigma-cli==${SIGMA_CLI_VERSION}" "pysigma-backend-splunk==${SPLUNK_VERSION}"
  "${SIGMA_ENV}/bin/python" -m pip freeze | grep -i "sigma\|yaml"
fi
PY="${SIGMA_ENV}/bin/python"
SIGMA="${SIGMA_ENV}/bin/sigma"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <workdir> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  (cd "$2" && GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    "${PY}" -I "${CHECK}" --rules-dir rules --tests-dir tests --sigma "${SIGMA}" --output "${TMP}/$1.json" "${@:3}") > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
errors() { jq -r '.errors | length' "${TMP}/$1.json"; }
copy() { rm -rf "${TMP:?}/$1"; cp -r "${FIX}" "${TMP}/$1"; }

echo "== sigma check on the fixtures: the broken rule is a rule error"
set +e
# -x attacktag -x d3_fendtag: those validators download MITRE data; the composite skips them too
(cd "${FIX}" && "${SIGMA}" check -x attacktag -x d3_fendtag --junitxml "${TMP}/check.xml" rules > "${TMP}/check.log" 2>&1)
check_rc=$?
set -e
[ "${check_rc}" -eq 1 ] || fail "sigma check should exit 1, got ${check_rc}: $(cat "${TMP}/check.log")"
[ -s "${TMP}/check.xml" ] || fail "sigma check wrote no JUnit file: $(cat "${TMP}/check.log")"
grep -q 'classname="SigmaIdentifierError"' "${TMP}/check.xml" || fail "JUnit lacks the identifier error: $(cat "${TMP}/check.xml")"

echo "== fixtures with require-test-case: syntax error + missing test case = 2 errors"
run fx "${FIX}" --junit "${TMP}/check.xml" --require-test-case
[ "${rc}" -eq 1 ] || fail "fixture rc ${rc}: $(cat "${TMP}/fx.log")"
grep -q '^::error file=rules/broken_rule_without_uuid.yml,title=sigma-lint::rules/broken_rule_without_uuid.yml: SigmaIdentifierError: Sigma rule identifier must be an UUID in rules/broken_rule_without_uuid.yml' "${TMP}/fx.log" || fail "rule error annotation: $(grep broken "${TMP}/fx.log")"
grep -q '^::error file=rules/aws_console_login_without_mfa.yml,title=sigma-lint::rules/aws_console_login_without_mfa.yml: no test case tests/7d1f0c2a-8b4e-4c6d-9e0f-aa11bb22cc33.yml' "${TMP}/fx.log" || fail "missing test case"
grep -q '^::warning file=rules/aws_console_login_without_mfa.yml,title=sigma-lint::rules/aws_console_login_without_mfa.yml: last modified 2024-06-01, older than 365 days (stale?)' "${TMP}/fx.log" || fail "stale warning"
grep -q 'tests/00000000-0000-4000-8000-000000000000.yml: test case for no rule (orphan)' "${TMP}/fx.log" || fail "orphan warning"
[ "$(errors fx)" = "2" ] || fail "error count $(errors fx): $(jq -c .errors "${TMP}/fx.json")"
[ "$(jq -r '.covered["rules/aws_iam_admin_policy_attached.yml"]' "${TMP}/fx.json")" = "stratus:aws.persistence.iam-create-admin-user" ] || fail "covered rule source"
grep -q '^## Sigma lint: 3 rule(s), 1 without a test case, 0 conversion failure(s), 1 stale, 2 error(s)' "${TMP}/fx.summary" || fail "summary: $(head -1 "${TMP}/fx.summary")"
grep -q '^| aws | 3 |' "${TMP}/fx.summary" || fail "product count"
[ "$(grep '^missing-test-count=' "${TMP}/fx.out" | cut -d= -f2)" = "1" ] || fail "missing-test-count output"

echo "== without require-test-case the missing test case is a warning"
run lax "${FIX}" --junit "${TMP}/check.xml"
[ "$(errors lax)" = "1" ] || fail "lax errors: $(jq -c .errors "${TMP}/lax.json")"
grep -q '^::warning file=rules/aws_console_login_without_mfa.yml,title=sigma-lint::rules/aws_console_login_without_mfa.yml: no test case' "${TMP}/lax.log" || fail "lax warning"

echo "== malformed test cases: bad technique, bad source, manual without steps, bad expect"
copy bad
cat > "${TMP}/bad/tests/2c9d3f2e-6f1a-4f0e-9a7c-1b2c3d4e5f60.yml" <<'EOT'
technique: 1098
source: manual
expect: maybe
EOT
run bad "${TMP}/bad" --require-test-case
grep -q '"technique" must be an ATT&CK id such as T1078.004, got "1098"' "${TMP}/bad.log" || fail "technique error"
grep -q 'a manual source needs "steps"' "${TMP}/bad.log" || fail "steps error"
grep -q '"expect" must be detected or prevented, got "maybe"' "${TMP}/bad.log" || fail "expect error"
printf 'technique: T1098.003\nsource: caldera:abc\nexpect: detected\n' > "${TMP}/bad/tests/2c9d3f2e-6f1a-4f0e-9a7c-1b2c3d4e5f60.yml"
run bad2 "${TMP}/bad" --require-test-case
grep -q '"source" must be atomic:<test guid>, stratus:<technique id> or manual, got "caldera:abc"' "${TMP}/bad2.log" || fail "source error"

echo "== splunk conversion: good rules convert, the broken one is a conversion failure"
run conv "${FIX}" --backend splunk --output-dir "${TMP}/converted"
[ "$(jq -r '.converted | length' "${TMP}/conv.json")" = "2" ] || fail "converted: $(jq -c .converted "${TMP}/conv.json")"
[ "$(jq -r '.failed | join(",")' "${TMP}/conv.json")" = "rules/broken_rule_without_uuid.yml" ] || fail "failed: $(jq -c .failed "${TMP}/conv.json")"
grep -q 'rules/broken_rule_without_uuid.yml: conversion to splunk failed: ' "${TMP}/conv.log" || fail "conversion error"
grep -qx 'eventSource="iam.amazonaws.com" eventName="AttachUserPolicy" requestParameters.policyArn="arn:aws:iam::aws:policy/AdministratorAccess"' "${TMP}/converted/aws_iam_admin_policy_attached.txt" || fail "converted query: $(cat "${TMP}/converted/aws_iam_admin_policy_attached.txt")"
[ ! -e "${TMP}/converted/broken_rule_without_uuid.txt" ] || fail "failed conversion must leave no file"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^Converted to `splunk`: 2 of 3.' "${TMP}/conv.summary" || fail "conversion summary"

echo "== missing rules directory is an error; empty one passes"
mkdir -p "${TMP}/none"
run none "${TMP}/none"
[ "${rc}" -eq 1 ] || fail "missing rules dir"
grep -q 'rules directory rules does not exist' "${TMP}/none.log" || fail "missing dir message"
mkdir -p "${TMP}/none/rules"
run empty "${TMP}/none"
[ "${rc}" -eq 0 ] || fail "empty rules dir rc ${rc}: $(cat "${TMP}/empty.log")"

echo "all sigma-lint checks passed"
