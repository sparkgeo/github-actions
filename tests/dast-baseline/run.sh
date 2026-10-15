#!/usr/bin/env bash
# ZAP baseline gate (issue #65) against a report recorded with ZAP 2.17.0 on
# fixtures/site (served with no security headers): 3 Medium, 6 Low and 2
# Informational alerts. Checks fail-on levels and the rules file
# (IGNORE 10036, WARN 10202, FAIL 10021). Needs python3.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../../.github/actions/zap-baseline/gate.py"
FIX="${HERE}/fixtures"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
gate() { status=0; python3 -I "${GATE}" --report "${FIX}/zap-report.json" "$@" > "${WORK}/out" 2> "${WORK}/err" || status=$?; }
count() { grep "^$1-count=" "${WORK}/out" | cut -d= -f2; }

gate --fail-on high
check "fail-on high: nothing blocks" "$(count medium)/$(count low)/$(count blocking)/${status}" "3/6/0/0"
check "Medium and Low alerts are warnings" "$(grep -c '^::warning title=ZAP baseline::' "${WORK}/err")" "9"
gate --fail-on medium
check "fail-on medium: the 3 Medium alerts block" "$(count blocking)/${status}" "3/1"
gate --fail-on low
check "fail-on low: every Medium and Low alert blocks" "$(count blocking)/${status}" "9/1"
gate --fail-on none
check "fail-on none reports only" "$(count blocking)/${status}" "0/0"

gate --fail-on medium --rules "${FIX}/rules.tsv"
check "rules: IGNORE drops 10036, WARN keeps 10202 from blocking, FAIL blocks 10021" \
  "$(count low)/$(count blocking)/${status}" "5/3/1"
check "the FAIL rule blocks even below fail-on" "$(grep -c '^::error title=ZAP baseline::X-Content-Type-Options Header Missing' "${WORK}/err")" "1"
gate --fail-on high --rules "${FIX}/rules.tsv"
check "rules at fail-on high: only the FAIL rule blocks" "$(count blocking)/${status}" "1/1"

printf '10021\tBLOCK\t(typo)\n' > "${WORK}/bad.tsv"
gate --fail-on high --rules "${WORK}/bad.tsv"
check "an unknown rule level is rejected" "$(grep -c 'rule level must be' "${WORK}/err")/${status}" "1/1"

exit "${fail}"
