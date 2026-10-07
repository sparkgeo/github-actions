#!/usr/bin/env bash
# Converts recorded `go test -json` output to JUnit with the go-test
# composite's converter, then runs the shared report script
# (.github/actions/pytest/report.py) in go mode and asserts the exit code,
# outputs and annotations. Executed in CI by the test-go job and locally
# with: bash tests/test-go/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONVERT="$ROOT/.github/actions/go-test/gotest2junit.py"
REPORT="$ROOT/.github/actions/pytest/report.py"
[ -f "$CONVERT" ] || { echo "FAIL: $CONVERT missing"; exit 1; }
[ -f "$REPORT" ] || { echo "FAIL: $REPORT missing"; exit 1; }

fails=0
# gotest json | coverage % | threshold | expected rc | expected failed | expected skipped | expected coverage | expected annotation (grep -c pattern)
while IFS='|' read -r json cov threshold want_rc want_failed want_skipped want_cov want_annot; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"; junit="$(mktemp)"
  export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" REPORT_TOOL=go
  MODULE_PATH=example.com/calc FILE_PREFIX=svc python3 -I "$CONVERT" "$HERE/fixtures/json/$json" "$junit" || { echo "FAIL $json: converter exited $?"; fails=$((fails+1)); continue; }
  export JUNIT_XML="$junit" COVERAGE_XML='' COVERAGE_PERCENT="$cov" COVERAGE_THRESHOLD="$threshold"
  python3 -I "$REPORT" > "$log" 2>&1; rc=$?
  got_failed="$(grep '^tests-failed=' "$out" | cut -d= -f2-)"
  got_skipped="$(grep '^tests-skipped=' "$out" | cut -d= -f2-)"
  got_cov="$(grep '^coverage-percent=' "$out" | cut -d= -f2-)"
  got_annot=$(grep -cE "^::error file=svc/calc/calc_test\.go,line=7,title=go example\.com/calc/calc::TestAdd::Add\(2, 3\) = 5, want 6" "$log")
  # A panic has no file:line in its output: the annotation must be job-level,
  # never the import path masquerading as a file.
  bad_file=$(grep -cE "^::error file=example\.com" "$log")
  if [ "$rc" = "$want_rc" ] && [ "$bad_file" = 0 ] && [ "$got_failed" = "$want_failed" ] && [ "$got_skipped" = "$want_skipped" ] && [ "$got_cov" = "$want_cov" ] && [ "$got_annot" = "$want_annot" ] && grep -q '^## go' "$summary"; then
    echo "ok   $json cov=$cov thr=$threshold -> rc=$rc failed=$got_failed skipped=$got_skipped cov=$got_cov annotation=$got_annot"
  else
    echo "FAIL $json cov=$cov thr=$threshold -> rc=$rc (want $want_rc) failed='$got_failed' (want '$want_failed') skipped='$got_skipped' (want '$want_skipped') cov='$got_cov' (want '$want_cov') annotation=$got_annot (want $want_annot)"; fails=$((fails+1))
  fi
done <<'CASES'
gotest-pass.jsonl|100.0|80|0|0|0|100.0|0
gotest-pass.jsonl|83.3|90|1|0|0|83.3|0
gotest-pass.jsonl|83.3|0|0|0|0|83.3|0
gotest-fail.jsonl|0.0|80|1|2|1|0.0|1
gotest-fail.jsonl|0.0|0|1|2|1|0.0|1
CASES
echo "$fails failure(s)"
exit "$fails"
