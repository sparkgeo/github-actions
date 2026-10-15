#!/usr/bin/env bash
# Runs the shared severity gate script against fixture findings
# files and asserts the exit code per fail-on-severity. Executed in CI by the
# severity-gate job and locally with: bash tests/severity-gate/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/severity-gate/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# fixture | format | fail-on | expected rc | expected max-severity output
while IFS='|' read -r fixture fmt fail_on want_rc want_sev; do
  out="$(mktemp)"; export GITHUB_OUTPUT="$out"; : > "$out"
  export FINDINGS_FILE="$HERE/fixtures/$fixture" FORMAT="$fmt" FAIL_ON="$fail_on"
  bash "$GATE" > /dev/null 2>&1; rc=$?
  got_sev="$(grep '^max-severity=' "$out" | cut -d= -f2-)"
  if [ "$rc" = "$want_rc" ] && [ "$got_sev" = "$want_sev" ]; then
    echo "ok   $fixture $fail_on -> rc=$rc max-severity=$got_sev"
  else
    echo "FAIL $fixture $fail_on -> rc=$rc (want $want_rc) max-severity='$got_sev' (want '$want_sev')"
    fails=$((fails+1))
  fi
done <<'CASES'
osv-empty.json|osv-json|critical|0|none
osv-empty.json|osv-json|low|0|none
osv-python-cvss-8.9.json|osv-json|critical|0|high
osv-python-cvss-8.9.json|osv-json|high|1|high
osv-python-cvss-8.9.json|osv-json|medium|1|high
osv-python-cvss-8.9.json|osv-json|none|0|high
osv-node-cvss-8.1.json|osv-json|critical|0|high
osv-node-cvss-8.1.json|osv-json|high|1|high
osv-node-cvss-8.1.json|osv-json|moderate|1|high
osv-node-cvss-8.1.json|osv-json|bogus|1|
osv-node-cvss-8.1.json|unknown-format|high|1|
CASES
echo "$fails failure(s)"
exit "$fails"
