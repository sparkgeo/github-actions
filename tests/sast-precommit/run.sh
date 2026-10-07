#!/usr/bin/env bash
# Runs the semgrep composite's gate script against recorded semgrep JSON
# output and asserts the exit code per fail-on-severity. Executed in CI by
# the sast-precommit job and locally with: bash tests/sast-precommit/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/semgrep/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# fixture | fail-on | expected rc | expected max-severity | expected annotations
while IFS='|' read -r fixture fail_on want_rc want_max want_annot; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"
  export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" RESULTS_JSON="$HERE/fixtures/$fixture" FAIL_ON="$fail_on"
  : > "$out"
  bash "$GATE" > "$log" 2>&1; rc=$?
  got_max="$(grep '^max-severity=' "$out" | cut -d= -f2-)"
  got_annot=$(grep -cE '^::(error|warning|notice) file=' "$log")
  if [ "$rc" = "$want_rc" ] && [ "$got_max" = "$want_max" ] && [ "$got_annot" = "$want_annot" ]; then
    echo "ok   $fixture $fail_on -> rc=$rc max=$got_max annotations=$got_annot"
  else
    echo "FAIL $fixture $fail_on -> rc=$rc (want $want_rc) max='$got_max' (want '$want_max') annotations=$got_annot (want $want_annot)"; fails=$((fails+1))
  fi
done <<'CASES'
results-insecure.json|high|1|high|3
results-insecure.json|medium|1|high|3
results-insecure.json|low|1|high|3
results-insecure.json|critical|1|high|3
results-insecure.json|none|0|high|3
results-clean.json|high|0|none|0
results-clean.json|none|0|none|0
results-insecure.json|bogus|1||0
CASES
echo "$fails failure(s)"
exit "$fails"
