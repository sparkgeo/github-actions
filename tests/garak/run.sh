#!/usr/bin/env bash
# Unit checks for the garak composite's guard and gate (issue #105). The live
# scan against tests/garak/stub.py runs in the ci.yml garak job.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="${HERE}/../../.github/actions/garak"
F="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== guard"
python3 -I "${A}/guard.py" --config "${F}/rest-echo.json" > /dev/null || fail "localhost refused"
if python3 -I "${A}/guard.py" --config "${F}/rest-prod.json" > /dev/null; then fail "prod host accepted"; fi
if python3 -I "${A}/guard.py" --config "${F}/rest-echo.json" --target-name https://www.example.com > /dev/null; then fail "www target accepted"; fi
python3 -I "${A}/guard.py" --config "${F}/rest-prod.json" --pattern '^nothing$' > /dev/null || fail "custom pattern ignored"
python3 -I "${A}/guard.py" --config "${F}/rest-echo.json" --pattern 'localhost' > /dev/null && fail "custom pattern not applied"

echo "== gate"
: > "${TMP}/out"
GITHUB_OUTPUT="${TMP}/out" python3 -I "${A}/gate.py" --report "${F}/report.jsonl" --max-hit-rate 0.1 --summary "${TMP}/sum" > /dev/null
grep -qx 'max-hit-rate=0.2000' "${TMP}/out" || fail "max-hit-rate: $(cat "${TMP}/out")"
grep -qx 'over-threshold=true' "${TMP}/out" || fail "over-threshold"
grep -qx 'failing=promptinject.HijackHateHumans/promptinject.AttackRogueString' "${TMP}/out" || fail "failing list"
head -5 "${TMP}/sum" | grep -q '| promptinject.HijackHateHumans | promptinject.AttackRogueString | 10 | 50 | 20.0% | over |' || fail "summary row"
: > "${TMP}/out"
GITHUB_OUTPUT="${TMP}/out" python3 -I "${A}/gate.py" --report "${F}/report.jsonl" --max-hit-rate 0.25 > /dev/null
grep -qx 'over-threshold=false' "${TMP}/out" || fail "0.25 threshold"
if python3 -I "${A}/gate.py" --report "${F}/report-empty.jsonl" --max-hit-rate 0.1 > /dev/null 2>&1; then fail "empty report passed"; fi
echo "all garak checks passed"
