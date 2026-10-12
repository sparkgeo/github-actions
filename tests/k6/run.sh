#!/usr/bin/env bash
# Checks summary.py against recorded k6 --summary-export files: metrics,
# thresholds, outputs and exit codes. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/k6/summary.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <name> <summary>; sets rc; writes $TMP/<name>/{log,out,summary}
  local name="$1" file="$2"
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --summary "${file}" --title "smoke" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== passing run"
run pass "${FIX}/summary-pass.json"
[ "${rc}" -eq 0 ] || fail "pass rc ${rc}: $(cat "${TMP}/pass/log")"
[ "$(output pass thresholds-failed)" = "0" ] || fail "pass thresholds-failed"
[ "$(output pass thresholds-total)" = "3" ] || fail "pass thresholds-total $(output pass thresholds-total)"
[ "$(output pass p95-ms)" = "1.0" ] || fail "pass p95-ms $(output pass p95-ms)"
[ "$(output pass error-rate)" = "0.0" ] || fail "pass error-rate $(output pass error-rate)"
[ "$(output pass requests)" = "6311" ] || fail "pass requests $(output pass requests)"
grep -q '^## Load test: smoke' "${TMP}/pass/summary" || fail "summary heading"
grep -qF '| http_req_duration | p(95)<2000 | pass |' "${TMP}/pass/summary" || fail "threshold row: $(cat "${TMP}/pass/summary")"
grep -q '| Requests | 6311 |' "${TMP}/pass/summary" || fail "requests row"
grep -qE '\| Requests per second \| 2103\.[0-9] \|' "${TMP}/pass/summary" || fail "rps row"
grep -qE '\| p95 latency \| 1\.0 ms \|' "${TMP}/pass/summary" || fail "p95 row"
grep -q '| Checks passed | 6311 / 6311 |' "${TMP}/pass/summary" || fail "checks row: $(grep Checks "${TMP}/pass/summary")"
! grep -q '^::error' "${TMP}/pass/log" || fail "pass must not emit errors"

echo "== threshold failure"
run failed "${FIX}/summary-fail.json"
[ "${rc}" -eq 1 ] || fail "fail rc ${rc}: $(cat "${TMP}/failed/log")"
[ "$(output failed thresholds-failed)" = "1" ] || fail "fail thresholds-failed $(output failed thresholds-failed)"
grep -qF '| http_req_duration | p(95)<0.001 | **fail** |' "${TMP}/failed/summary" || fail "failed threshold row: $(grep http_req_duration "${TMP}/failed/summary")"
grep -q '^::error title=k6::threshold http_req_duration p(95)<0.001 crossed' "${TMP}/failed/log" || fail "failed annotation: $(cat "${TMP}/failed/log")"

echo "== missing summary exits 2"
run missing "${TMP}/nope.json"
[ "${rc}" -eq 2 ] || fail "missing rc ${rc}"
grep -q '^::error title=k6::' "${TMP}/missing/log" || fail "missing annotation"

echo "all k6 checks passed"
