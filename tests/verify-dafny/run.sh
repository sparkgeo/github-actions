#!/usr/bin/env bash
# Checks the Dafny composite's script: the verify report on a real failing
# proof and on a recorded time-out, the drift check (a changed byte, a
# missing generated file, an extra committed file that is allowed) against
# the example's committed output, and the brief and gate. Needs dafny on PATH
# (the composite puts it there), python3 and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PY="${ROOT}/.github/actions/dafny/dafny.py"
FIX="${HERE}/fixtures"
EXAMPLE="${ROOT}/docs/examples/verify/dafny/compiled"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
command -v dafny >/dev/null || { echo "FAIL: dafny not on PATH" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }

echo "== report: a false postcondition fails with its location"
A="${TMP}/bad"; mkdir -p "${A}"
cp "${FIX}/bad.dfy.txt" "${A}/bad.dfy"
cd "${A}"
set +e
dafny verify --verification-time-limit 60 bad.dfy > "${A}/dafny.txt" 2>&1
rc=$?
set -e
[ "${rc}" -ne 0 ] || fail "dafny verify passed a false postcondition"
python3 -I "${PY}" report --log "${A}/dafny.txt" --rc "${rc}" --output "${A}/dafny.json" > "${A}/report.log"
[ "$(j "${A}/dafny.json" '[.errors, .timeouts, (.failures | length)] | join(",")')" = "1,0,1" ] || fail "counts: $(cat "${A}/dafny.json")"
[ "$(j "${A}/dafny.json" '.failures[0] | .file + ":" + (.line|tostring) + ":" + .kind')" = "bad.dfy:8:error" ] || fail "location: $(j "${A}/dafny.json" '.failures[0]')"
grep -q '^::error file=bad.dfy,line=8,col=' "${A}/report.log" || fail "annotation: $(head -3 "${A}/report.log")"

echo "== report: a recorded time-out is a failure of kind timeout"
B="${TMP}/to"; mkdir -p "${B}"
python3 -I "${PY}" report --log "${FIX}/timeout.txt" --rc 4 --output "${B}/dafny.json" > /dev/null
[ "$(j "${B}/dafny.json" '[.verified, .errors, .timeouts, .failures[0].kind] | join(",")')" = "8,0,1,timeout" ] || fail "timeout: $(cat "${B}/dafny.json")"

echo "== drift: identical tree is clean; extra committed files allowed"
C="${TMP}/drift"; mkdir -p "${C}"
cp -r "${EXAMPLE}/py" "${C}/gen"; cp -r "${EXAMPLE}/py" "${C}/com"
find "${C}/gen" -name 'test_*.py' -delete
python3 -I "${PY}" drift --generated "${C}/gen" --committed "${C}/com" --target py --output "${C}/drift-py.json" > /dev/null
[ "$(j "${C}/drift-py.json" '[(.missing|length), (.changed|length)] | join(",")')" = "0,0" ] || fail "clean drift: $(cat "${C}/drift-py.json")"

echo "== drift: a changed byte and a missing generated file are reported"
printf '\n# edited by hand\n' >> "${C}/com/Quadkey.py"
rm "${C}/com/module_.py"
python3 -I "${PY}" drift --generated "${C}/gen" --committed "${C}/com" --target py --output "${C}/drift-py.json" > "${C}/drift.log"
[ "$(j "${C}/drift-py.json" '.changed | join(",")')" = "Quadkey.py" ] || fail "changed: $(cat "${C}/drift-py.json")"
[ "$(j "${C}/drift-py.json" '.missing | join(",")')" = "module_.py" ] || fail "missing"
grep -q '::error file=.*/com/Quadkey.py,title=dafny drift (py)::' "${C}/drift.log" || fail "drift annotation"

echo "== brief and gate: verification failure and drift both block"
cp "${A}/dafny.json" "${C}/dafny.json"
set +e
GITHUB_OUTPUT="${C}/out.txt" python3 -I "${PY}" brief --art "${C}" --gate > "${C}/brief.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "gate rc ${rc}"
grep -q 'FAIL: Dafny verification failed: 1 error(s), 0 time out(s)' "${C}/brief.log" || fail "verify gate: $(cat "${C}/brief.log")"
grep -q 'FAIL: py compiled output in .* is out of date (1 missing, 1 different)' "${C}/brief.log" || fail "drift gate"
grep -q '^| py | ' "${C}/verify-brief.md" || fail "drift table"
[ "$(j "${C}/summary.json" '[.tool, .dafny != 0, .drift] | join(",")')" = "verify-dafny,true,2" ] || fail "summary.json: $(cat "${C}/summary.json")"
grep -q '^blocking=2$' "${C}/out.txt" || fail "outputs"

echo "all dafny checks passed"
