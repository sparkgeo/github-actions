#!/usr/bin/env bash
# Runs the codeql-gate composite's gate script against CodeQL-shaped SARIF
# fixtures and asserts the exit code per fail-on-severity. Executed in CI by
# the sast-scan job and locally with: bash tests/sast-scan/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/codeql-gate/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# fixture | fail-on | expected rc | expected max-severity | expected file annotations
while IFS='|' read -r fixture fail_on want_rc want_max want_annot; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"; sdir="$(mktemp -d)"
  export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" SARIF_DIR="$sdir" FAIL_ON="$fail_on"
  cp "$HERE/fixtures/$fixture" "$SARIF_DIR/python.sarif"
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
results-insecure.sarif|critical|1|critical|4
results-insecure.sarif|high|1|critical|4
results-insecure.sarif|medium|1|critical|4
results-insecure.sarif|low|1|critical|4
results-insecure.sarif|none|0|critical|4
results-quality-only.sarif|high|0|none|1
results-quality-only.sarif|low|0|none|1
results-clean.sarif|high|0|none|0
results-insecure.sarif|bogus|1||0
CASES
echo "$fails failure(s)"
exit "$fails"
