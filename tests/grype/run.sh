#!/usr/bin/env bash
# Checks gate.sh (the gate behind .github/actions/grype) against recorded
# grype JSON output. Needs jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../../.github/actions/grype/gate.sh"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_gate() {  # <results> <fail-on-severity>
  rm -f "${TMP}/out" "${TMP}/summary"
  touch "${TMP}/out" "${TMP}/summary"
  set +e
  RESULTS="$1" FAIL_ON_SEVERITY="$2" \
    GITHUB_OUTPUT="${TMP}/out" GITHUB_STEP_SUMMARY="${TMP}/summary" \
    bash "${GATE}" > "${TMP}/log" 2>&1
  rc=$?
  set -e
}

# Fixture: 7 High (urllib3 1.26.5) + 6 Medium (3 requests 2.31.0, 3 urllib3), all fixed.
echo "== critical threshold: High/Medium findings warn but pass"
run_gate "${FIX}/results/vuln.json" critical
[ "${rc}" -eq 0 ] || { cat "${TMP}/log"; fail "critical: expected rc 0, got ${rc}"; }
[ "$(grep -c '^::warning title=grype' "${TMP}/log")" -eq 13 ] || fail "critical: expected 13 warning annotations"
[ "$(grep -c '^::error title=grype' "${TMP}/log")" -eq 0 ] || fail "critical: expected no error annotations"
grep -q '^match-count=13$' "${TMP}/out" || fail "critical: match-count output"
grep -q '^blocking-count=0$' "${TMP}/out" || fail "critical: blocking-count output"

echo "== high threshold: 7 block"
run_gate "${FIX}/results/vuln.json" high
[ "${rc}" -eq 1 ] || fail "high: expected rc 1, got ${rc}"
[ "$(grep -c '^::error title=grype' "${TMP}/log")" -eq 7 ] || fail "high: expected 7 error annotations"
[ "$(grep -c '^::warning title=grype' "${TMP}/log")" -eq 6 ] || fail "high: expected 6 warning annotations"
grep -q '^::error title=grype::GHSA-38jv-5279-wg99 High urllib3 1.26.5 (fixed in 2.6.3)$' "${TMP}/log" || fail "high: annotation format"
grep -q '^blocking-count=7$' "${TMP}/out" || fail "high: blocking-count output"
grep -q '| High | 7 | 7 |' "${TMP}/summary" || fail "high: summary row for High"
grep -q '| Medium | 6 | 0 |' "${TMP}/summary" || fail "high: summary row for Medium"

echo "== medium threshold: all 13 block"
run_gate "${FIX}/results/vuln.json" medium
[ "${rc}" -eq 1 ] || fail "medium: expected rc 1, got ${rc}"
grep -q '^blocking-count=13$' "${TMP}/out" || fail "medium: blocking-count output"

echo "== clean results pass"
run_gate "${FIX}/results/clean.json" low
[ "${rc}" -eq 0 ] || fail "clean: expected rc 0, got ${rc}"
grep -q '^match-count=0$' "${TMP}/out" || fail "clean: match-count output"
grep -q 'No vulnerabilities' "${TMP}/summary" || fail "clean: summary"

echo "== bad threshold rejected"
run_gate "${FIX}/results/clean.json" severe
[ "${rc}" -eq 2 ] || fail "bad threshold: expected rc 2, got ${rc}"
grep -q '::error.*severe' "${TMP}/log" || fail "bad threshold: error annotation"

echo "== missing results file"
run_gate "${TMP}/nope.json" critical
[ "${rc}" -eq 2 ] || fail "missing results: expected rc 2, got ${rc}"

echo "PASS"
