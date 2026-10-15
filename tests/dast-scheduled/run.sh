#!/usr/bin/env bash
# Scheduled DAST (issue #68): the production guard, report.py over recorded
# ZAP and nuclei results, and issue.sh against a fake gh (open once, then
# update; comment only when a new High or Critical finding appears).
# Fixtures: ../dast-baseline/fixtures/zap-report.json (Medium and Low only),
# fixtures/zap-api.json (SQL Injection, High) and
# ../dast-nuclei/fixtures/nuclei-results.json (exposed-gitmodules, high).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/../../.github/actions/dast-report"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
PATTERN='(^|[.-])(prod|production|live)([.-]|$)|^www\.'

guard() { status=0; python3 -I "${DIR}/guard.py" --target "$1" --pattern "${2:-${PATTERN}}" > /dev/null 2>&1 || status=$?; echo "${status}"; }
check "staging host passes the guard" "$(guard https://staging.example.com/)" "0"
check "localhost passes the guard" "$(guard http://127.0.0.1:8080/)" "0"
check "prod host is refused" "$(guard https://api.prod.example.com/)" "1"
check "production label is refused" "$(guard https://app-production.example.com)" "1"
check "www host is refused" "$(guard https://www.example.com)" "1"
check "a custom pattern is honoured" "$(guard https://maps.example.com 'maps\.example\.com$')" "1"
check "a non-http target is refused" "$(guard ftp://staging.example.com)" "1"

report() { status=0; python3 -I "${DIR}/report.py" --out "${WORK}/findings.json" "$@" > "${WORK}/out" 2> "${WORK}/err" || status=$?; }
report --fail-on high --zap "${HERE}/../dast-baseline/fixtures/zap-report.json" --zap "${HERE}/fixtures/zap-api.json" \
  --nuclei "${HERE}/../dast-nuclei/fixtures/nuclei-results.json"
check "two High findings block at fail-on high" "$(grep blocking "${WORK}/out")/${status}/$(jq length "${WORK}/findings.json")" "blocking-count=2/1/2"
check "findings carry stable keys" "$(jq -r '[.[].key] | sort | join(" ")' "${WORK}/findings.json")" \
  "nuclei:exposed-gitmodules:/.gitmodules zap:40018:/api/items"
report --fail-on critical --zap "${HERE}/../dast-baseline/fixtures/zap-report.json" --zap "${WORK}/missing.json"
check "a missing report is skipped; Medium does not block" "$(grep blocking "${WORK}/out")/${status}/$(jq length "${WORK}/findings.json")" "blocking-count=0/0/0"

echo '[]' > "${WORK}/issues.json"; : > "${WORK}/gh.log"
issue() { PATH="${HERE}/fake-gh:${PATH}" FAKE_GH_STATE="${WORK}/issues.json" FAKE_GH_LOG="${WORK}/gh.log" REPO=o/r \
  TARGET=https://staging.example.com FINDINGS="$1" RUN_URL="https://example.invalid/run/$2" bash "${DIR}/issue.sh" > /dev/null; }
echo '[]' > "${WORK}/none.json"
issue "${WORK}/none.json" 0
check "no findings and no issue: nothing written" "$(wc -l < "${WORK}/gh.log" | tr -d ' ')" "0"
report --fail-on high --zap "${HERE}/fixtures/zap-api.json"
cp "${WORK}/findings.json" "${WORK}/run1.json"
issue "${WORK}/run1.json" 1
check "first High finding opens one issue" "$(grep -c '^create DAST scheduled scan: staging.example.com' "${WORK}/gh.log")" "1"
: > "${WORK}/gh.log"
issue "${WORK}/run1.json" 2
check "same findings next week: body updated, no comment" "$(grep -c '^edit 1' "${WORK}/gh.log")/$(grep -c '^comment' "${WORK}/gh.log" || true)" "1/0"
report --fail-on high --zap "${HERE}/fixtures/zap-api.json" --nuclei "${HERE}/../dast-nuclei/fixtures/nuclei-results.json"
: > "${WORK}/gh.log"
issue "${WORK}/findings.json" 3
check "a new High finding comments and names it" "$(grep -c '^comment 1 .*nuclei:exposed-gitmodules' "${WORK}/gh.log")/$(grep -c '^create' "${WORK}/gh.log" || true)" "1/0"

exit "${fail}"
