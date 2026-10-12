#!/usr/bin/env bash
# Checks summary.py against recorded Playwright JUnit files: counts, step
# summary, outputs and exit codes. Needs python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/playwright/summary.py"
FIX="${HERE}/fixtures/junit"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <name> <junit> [args]; sets rc; writes $TMP/<name>/{log,out,summary}
  local name="$1" file="$2"; shift 2
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --junit "${file}" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== passing run with a skipped test"
run pass "${FIX}/pass.xml" --shard 1/2
[ "${rc}" -eq 0 ] || fail "pass rc ${rc}: $(cat "${TMP}/pass/log")"
[ "$(output pass tests-total)" = "3" ] || fail "pass tests-total $(output pass tests-total)"
[ "$(output pass tests-failed)" = "0" ] || fail "pass tests-failed"
[ "$(output pass tests-skipped)" = "1" ] || fail "pass tests-skipped"
grep -q '^## Playwright (shard 1/2): 3 tests, 0 failed, 1 skipped' "${TMP}/pass/summary" || fail "pass heading: $(head -1 "${TMP}/pass/summary")"
grep -qF '| home.spec.js | 2 | 0 | 0 |' "${TMP}/pass/summary" || fail "suite row: $(cat "${TMP}/pass/summary")"
! grep -q '^::error' "${TMP}/pass/log" || fail "pass must not emit errors"

echo "== failing run"
run failed "${FIX}/fail.xml"
[ "${rc}" -eq 1 ] || fail "fail rc ${rc}: $(cat "${TMP}/failed/log")"
[ "$(output failed tests-failed)" = "1" ] || fail "fail tests-failed"
grep -q '^## Playwright: 3 tests, 1 failed, 0 skipped' "${TMP}/failed/summary" || fail "fail heading: $(head -1 "${TMP}/failed/summary")"
grep -qF '| failing.spec.js | 1 | 1 | 0 |' "${TMP}/failed/summary" || fail "fail suite row"
grep -qF 'deliberately failing when E2E_FIXTURE_FAIL is set' "${TMP}/failed/summary" || fail "failed test listed"
grep -qF 'Expected string: "Goodbye"' "${TMP}/failed/summary" || fail "failure message listed"
! grep -q '^::error' "${TMP}/failed/log" || fail "annotations come from the github reporter, not summary.py"

echo "== missing junit exits 2"
run missing "${TMP}/nope.xml"
[ "${rc}" -eq 2 ] || fail "missing rc ${rc}"
grep -q '^::error title=playwright::' "${TMP}/missing/log" || fail "missing annotation"

echo "all e2e-playwright checks passed"
