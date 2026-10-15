#!/usr/bin/env bash
# Checks the axe composite's report.py against recorded axe-core results: the
# summary counts, per-rule annotations, the HTML report, report-only mode and
# the gate. The live axe run against tests/a11y/fixtures/site happens in the
# CI job (Chrome on the runner). Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
REPORT="${ROOT}/.github/actions/axe/report.py"
RESULTS="${HERE}/fixtures/axe-results.json"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${REPORT}" --results "${RESULTS}" --html "${TMP}/$1.html" --output "${TMP}/$1.json" "${@:2}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}

echo "== gate: three violations on one page fail the job, annotated as errors"
run gate --fail-on-violations
[ "${rc}" -eq 1 ] || fail "gate rc ${rc}: $(cat "${TMP}/gate.log")"
grep -q '^::error title=a11y image-alt (critical)::http://127.0.0.1:4173/index.html: Images must have alternative text; 1 element(s): img$' "${TMP}/gate.log" || fail "annotation: $(grep image-alt "${TMP}/gate.log")"
[ "$(grep -c '^::error ' "${TMP}/gate.log")" = "3" ] || fail "three error annotations"
grep -q '^## Accessibility scan: 2 page(s), 3 violation(s) (1 critical, 2 serious)' "${TMP}/gate.summary" || fail "summary heading: $(head -1 "${TMP}/gate.summary")"
grep -q '^| http://127.0.0.1:4173/index.html | 3 | 3 | 1 |' "${TMP}/gate.summary" || fail "page row"
grep -q '^| http://127.0.0.1:4173/clean.html | 0 | 0 | 0 |' "${TMP}/gate.summary" || fail "clean page row"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| http://127.0.0.1:4173/index.html | critical | \[`image-alt`\](https://dequeuniversity.com/rules/axe/4.13/image-alt) | 1 | Images must have alternative text |' "${TMP}/gate.summary" || fail "rule row"
[ "$(grep '^violation-count=' "${TMP}/gate.out" | cut -d= -f2)" = "3" ] || fail "violation-count output"
[ "$(jq -r '.by_impact.critical + .by_impact.serious' "${TMP}/gate.json")" = "3" ] || fail "by_impact"
grep -q '<h3 class="critical">image-alt (critical): Images must have alternative text</h3>' "${TMP}/gate.html" || fail "html report heading"
grep -q '&lt;img src=&quot;logo.png&quot;&gt;' "${TMP}/gate.html" || fail "html report escapes the offending markup"

echo "== report-only mode: same findings as warnings, exit 0"
run report
[ "${rc}" -eq 0 ] || fail "report-only rc ${rc}"
[ "$(grep -c '^::warning ' "${TMP}/report.log")" = "3" ] || fail "three warning annotations"
grep -q 'Report-only mode: violations do not fail the job.' "${TMP}/report.summary" || fail "report-only note"

echo "== clean results pass the gate"
jq '[.[1]]' "${RESULTS}" > "${TMP}/clean.json"
set +e
GITHUB_OUTPUT="${TMP}/clean.out" python3 -I "${REPORT}" --results "${TMP}/clean.json" --fail-on-violations > "${TMP}/clean.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "clean rc ${rc}: $(cat "${TMP}/clean.log")"
grep -q '^## Accessibility scan: 1 page(s), 0 violations' "${TMP}/clean.log" || fail "clean summary"

echo "all a11y checks passed"
