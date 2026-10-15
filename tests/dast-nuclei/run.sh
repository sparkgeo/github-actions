#!/usr/bin/env bash
# nuclei gate (issue #66) on a JSON export: exposed-gitmodules (high, recorded
# with nuclei 3.11.1 and nuclei-templates 10.5.0 against fixtures/site) plus
# one medium and one info finding added by hand. Needs python3.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../../.github/actions/nuclei/gate.py"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
gate() { status=0; python3 -I "${GATE}" --results "$1" --fail-on "$2" > "${WORK}/out" 2> "${WORK}/err" || status=$?; }
blocking() { grep '^blocking-count=' "${WORK}/out" | cut -d= -f2; }

gate "${HERE}/fixtures/nuclei-results.json" high
check "fail-on high: the exposed .gitmodules blocks" "$(blocking)/${status}/$(grep -c '^::error title=nuclei high exposed-gitmodules::' "${WORK}/err")" "1/1/1"
gate "${HERE}/fixtures/nuclei-results.json" medium
check "fail-on medium adds the medium finding" "$(blocking)/${status}" "2/1"
gate "${HERE}/fixtures/nuclei-results.json" info
check "fail-on info blocks all three" "$(blocking)/${status}" "3/1"
gate "${HERE}/fixtures/nuclei-results.json" critical
check "fail-on critical: nothing blocks, all reported" "$(blocking)/${status}/$(grep -c '^::warning' "${WORK}/err")" "0/0/3"
gate "${HERE}/fixtures/nuclei-results.json" none
check "fail-on none reports only" "$(blocking)/${status}" "0/0"
gate "${WORK}/missing.json" high
check "no export (no findings) passes" "$(blocking)/${status}" "0/0"

exit "${fail}"
