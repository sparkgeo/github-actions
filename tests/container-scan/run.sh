#!/usr/bin/env bash
# Runs the trivy composite's gate script against recorded trivy JSON output
# and asserts the exit code per fail-on-severity. Executed in CI by the
# container-scan job and locally with: bash tests/container-scan/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/trivy/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# fixture | fail-on | expected rc | expected max-severity | expected critical-count
while IFS='|' read -r fixture fail_on want_rc want_max want_crit; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"; export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary"; : > "$out"
  export RESULTS_JSON="$HERE/fixtures/$fixture" FAIL_ON="$fail_on"
  bash "$GATE" > "$log" 2>&1; rc=$?
  got_max="$(grep '^max-severity=' "$out" | cut -d= -f2-)"
  got_crit="$(grep '^critical-count=' "$out" | cut -d= -f2-)"
  if [ "$rc" = "$want_rc" ] && [ "$got_max" = "$want_max" ] && [ "$got_crit" = "$want_crit" ]; then
    echo "ok   $fixture $fail_on -> rc=$rc max=$got_max critical=$got_crit"
  else
    echo "FAIL $fixture $fail_on -> rc=$rc (want $want_rc) max='$got_max' (want '$want_max') critical='$got_crit' (want '$want_crit')"; fails=$((fails+1))
  fi
done <<'CASES'
results-alpine-3.18.0.json|critical|1|critical|3
results-alpine-3.18.0.json|high|1|critical|3
results-alpine-3.18.0.json|medium|1|critical|3
results-alpine-3.18.0.json|low|1|critical|3
results-alpine-3.18.0.json|none|0|critical|3
results-chainguard-static.json|critical|0|none|0
results-chainguard-static.json|low|0|none|0
results-alpine-3.18.0.json|bogus|1||
CASES
echo "$fails failure(s)"
exit "$fails"
