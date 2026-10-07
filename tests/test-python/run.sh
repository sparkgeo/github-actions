#!/usr/bin/env bash
# Runs the pytest composite's report script against recorded JUnit and
# coverage XML and asserts the exit code, outputs and annotations. Executed
# in CI by the test-python job and locally with: bash tests/test-python/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPORT="$ROOT/.github/actions/pytest/report.py"
[ -f "$REPORT" ] || { echo "FAIL: $REPORT missing"; exit 1; }

fails=0
# junit | coverage | threshold | expected rc | expected failed | expected coverage | expected ::error annotations
while IFS='|' read -r junit cov threshold want_rc want_failed want_cov want_annot; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"
  export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary"
  export JUNIT_XML="$HERE/fixtures/xml/$junit" COVERAGE_XML="$HERE/fixtures/xml/$cov" COVERAGE_THRESHOLD="$threshold"
  [ "$cov" = "-" ] && export COVERAGE_XML="$HERE/fixtures/xml/does-not-exist.xml"
  python3 "$REPORT" > "$log" 2>&1; rc=$?
  got_failed="$(grep '^tests-failed=' "$out" | cut -d= -f2-)"
  got_cov="$(grep '^coverage-percent=' "$out" | cut -d= -f2-)"
  got_annot=$(grep -cE '^::error file=' "$log")
  if [ "$rc" = "$want_rc" ] && [ "$got_failed" = "$want_failed" ] && [ "$got_cov" = "$want_cov" ] && [ "$got_annot" = "$want_annot" ]; then
    echo "ok   $junit $cov thr=$threshold -> rc=$rc failed=$got_failed cov=$got_cov annotations=$got_annot"
  else
    echo "FAIL $junit $cov thr=$threshold -> rc=$rc (want $want_rc) failed='$got_failed' (want '$want_failed') cov='$got_cov' (want '$want_cov') annotations=$got_annot (want $want_annot)"; fails=$((fails+1))
  fi
done <<'CASES'
junit-pass.xml|coverage-100.xml|80|0|0|100.0|0
junit-pass.xml|coverage-partial.xml|80|0|0|83.3|0
junit-pass.xml|coverage-partial.xml|90|1|0|83.3|0
junit-fail.xml|coverage-partial.xml|80|1|2|83.3|2
junit-fail.xml|coverage-partial.xml|90|1|2|83.3|2
junit-pass.xml|coverage-100.xml|0|0|0|100.0|0
junit-pass.xml|-|80|1|0||0
CASES
echo "$fails failure(s)"
exit "$fails"
