#!/usr/bin/env bash
# Malicious-package check (issue #229): scan the fixture packages with GuardDog
# and run gate.py on the results.
#   - the PyPI install hook and the npm postinstall downloader are high_risk
#   - with fail-on high both block; with the allowlist only the PyPI one does,
#     and the npm one is a suppressed SARIF result
#   - an allowlist entry without a reviewer is rejected
# Usage: tests/guarddog/run.sh <guarddog venv bin dir>
set -euo pipefail
BIN="${1:?usage: run.sh <venv bin dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${HERE}/../../.github/actions/guarddog"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
mkdir -p "${WORK}/results"

wrap() {  # verify-shaped list from a single `scan` result
  "${BIN}/python" -I -c 'import json,sys; r=json.load(open(sys.argv[1])); json.dump([{"dependency": sys.argv[2], "version": sys.argv[3], "result": r}], open(sys.argv[4], "w"))' "$@"
}
"${BIN}/guarddog" pypi scan "${HERE}/fixtures/pypi-install-hook" --output-format json > "${WORK}/p.json"
wrap "${WORK}/p.json" fixture-install-hook 0.0.1 "${WORK}/results/pypi.json"
"${BIN}/guarddog" npm scan "${HERE}/fixtures/npm-postinstall" --output-format json > "${WORK}/n.json"
wrap "${WORK}/n.json" fixture-postinstall 0.0.1 "${WORK}/results/npm-0.json"
printf '{"pypi:fixture-install-hook@0.0.1": "tests/guarddog/fixtures/pypi-install-hook/setup.py", "npm:fixture-postinstall@0.0.1": "tests/guarddog/fixtures/npm-postinstall/package.json"}' > "${WORK}/sources.json"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
gate() { "${BIN}/python" -I "${ACTION}/gate.py" --results "${WORK}/results" --sources "${WORK}/sources.json" --sarif "${WORK}/out.sarif" "$@" 2>"${WORK}/stderr"; }
count() { grep -o "^$1-count=[0-9]*" "${WORK}/out" | cut -d= -f2; }

status=0; gate --fail-on high > "${WORK}/out" || status=$?
check "both fixtures block at fail-on high" "$(count blocking)/${status}" "2/1"

status=0; gate --fail-on high --allowlist "${HERE}/fixtures/allowlist.yml" > "${WORK}/out" || status=$?
check "allowlisted npm fixture no longer blocks" "$(count blocking)/$(count flagged)/${status}" "1/2/1"
check "allowlisted findings are suppressed in SARIF" \
  "$("${BIN}/python" -I -c 'import json,sys; print(sum(1 for r in json.load(open(sys.argv[1]))["runs"][0]["results"] if r.get("suppressions")))' "${WORK}/out.sarif")" "2"

status=0; gate --fail-on none > "${WORK}/out" || status=$?
check "fail-on none reports only" "$(count blocking)/${status}" "0/0"

printf 'exceptions:\n  - package: x@1\n    rule: typosquatting\n    date: 2026-10-15\n' > "${WORK}/bad.yml"
status=0; gate --fail-on high --allowlist "${WORK}/bad.yml" > "${WORK}/out" || status=$?
check "allowlist entry without a reviewer is rejected" "$(grep -c 'missing reviewer' "${WORK}/stderr")/${status}" "1/1"

exit "${fail}"
