#!/usr/bin/env bash
# Runs the checkov composite's gate script against recorded checkov JSON
# output and asserts the exit code per fail-on-severity. Executed in CI by
# the iac-scan job and locally with: bash tests/iac-scan/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/checkov/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# fixture | fail-on | expected rc | expected failed-count | expect annotation
while IFS='|' read -r fixture fail_on want_rc want_count want_annot; do
  out="$(mktemp)"; log="$(mktemp)"; export GITHUB_OUTPUT="$out"; : > "$out"
  export RESULTS_JSON="$HERE/fixtures/$fixture" FAIL_ON="$fail_on" DIRECTORY="tests/iac-scan/fixtures/x"
  bash "$GATE" > "$log" 2>&1; rc=$?
  got_count="$(grep '^failed-count=' "$out" | cut -d= -f2-)"
  got_annot=$(grep -c '^::warning file=' "$log")
  ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  [ "$got_count" = "$want_count" ] || ok=0
  if [ "$want_annot" = "yes" ]; then [ "$got_annot" -gt 0 ] || ok=0; else [ "$got_annot" -eq 0 ] || ok=0; fi
  if [ "$ok" = 1 ]; then
    echo "ok   $fixture $fail_on -> rc=$rc failed-count=$got_count annotations=$got_annot"
  else
    echo "FAIL $fixture $fail_on -> rc=$rc (want $want_rc) failed-count='$got_count' (want '$want_count') annotations=$got_annot (want $want_annot)"
    fails=$((fails+1))
  fi
done <<'CASES'
results-insecure.json|high|1|19|yes
results-insecure.json|medium|1|19|yes
results-insecure.json|low|1|19|yes
results-insecure.json|critical|0|19|yes
results-insecure.json|none|0|19|yes
results-clean.json|high|0|0|no
results-clean.json|none|0|0|no
results-insecure.json|bogus|1||no
CASES
echo "$fails failure(s)"
exit "$fails"
