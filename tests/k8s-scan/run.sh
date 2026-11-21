#!/usr/bin/env bash
# Runs the k8s-scan composite's gate script against recorded trivy JSON
# result sets (chart misconfigurations, rendered kustomize overlay, image
# vulnerabilities) and asserts the exit code, max-severity and annotation
# shape per fail-on-severity. Executed in CI by the k8s-scan job and locally
# with: bash tests/k8s-scan/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$ROOT/.github/actions/k8s-scan/gate.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE missing"; exit 1; }

fails=0
# results dir | fail-on | expected rc | expected max-severity | expected inline helm annotations (file=...,line=) | expected job-level kustomize annotations
while IFS='|' read -r set fail_on want_rc want_max want_inline want_joblevel; do
  out="$(mktemp)"; log="$(mktemp)"; summary="$(mktemp)"
  export GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" RESULTS_DIR="$HERE/fixtures/results/$set" FAIL_ON="$fail_on"
  : > "$out"
  ( cd "$ROOT" && bash "$GATE" > "$log" 2>&1 ); rc=$?
  got_max="$(grep '^max-severity=' "$out" | cut -d= -f2-)"
  got_inline=$(grep -cE '^::(error|warning|notice) file=tests/k8s-scan/fixtures/charts/[a-z]+/templates/deployment\.yaml,line=[0-9]+,title=trivy (CRITICAL|HIGH|MEDIUM|LOW) KSV-' "$log")
  got_joblevel=$(grep -cE '^::(error|warning|notice) title=trivy (CRITICAL|HIGH|MEDIUM|LOW) KSV-[0-9]+::.* in kustomize overlay ' "$log")
  if [ "$rc" = "$want_rc" ] && [ "$got_max" = "$want_max" ] && [ "$got_inline" = "$want_inline" ] && [ "$got_joblevel" = "$want_joblevel" ]; then
    echo "ok   $set $fail_on -> rc=$rc max=$got_max inline=$got_inline job-level=$got_joblevel"
  else
    echo "FAIL $set $fail_on -> rc=$rc (want $want_rc) max='$got_max' (want '$want_max') inline=$got_inline (want $want_inline) job-level=$got_joblevel (want $want_joblevel)"; fails=$((fails+1))
  fi
done <<'CASES'
insecure|critical|1|critical|21|3
insecure|high|1|critical|21|3
insecure|none|0|critical|21|3
clean|high|0|medium|3|3
clean|medium|1|medium|3|3
clean|none|0|medium|3|3
insecure|bogus|1||0|0
CASES
echo "$fails failure(s)"
exit "$fails"
