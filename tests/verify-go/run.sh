#!/usr/bin/env bash
# Checks the verify-go composite's scripts: the fuzz-target AST check
# (fuzzcover.go: mapped exported functions with and without a Fuzz* caller,
# external test packages, rapid/quick detection), a real crasher found by the
# per-PR fuzz and its reproduction command, corpus hygiene, high-risk
# packages with no property, the gremlins score and the gate (go.py,
# summary.py). Needs go, python3 and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ACT="${ROOT}/.github/actions/verify-go"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }
summary() {  # <art> [args]; sets rc
  set +e
  GITHUB_OUTPUT="$1/out.txt" python3 -I "${ACT}/summary.py" --art "$1" "${@:2}" > "$1/summary.log" 2>&1
  rc=$?
  set -e
}

M="${TMP}/mod"; A="${TMP}/art"
cp -r "${FIX}/mod" "${M}"; mkdir -p "${A}/status"
cd "${M}"

echo "== fuzzcover: mapped Uncovered has no Fuzz* caller; Covered fuzzed from an external test package; quick.Check detected"
printf 'geo\nauth\ncrash\n' > "${A}/pkgs.txt"
printf 'geo/geo.go\nauth/auth.go\n' > "${A}/mapped.txt"
go run "${ACT}/fuzzcover.go" -root . -pkgs "${A}/pkgs.txt" -mapped "${A}/mapped.txt" -out "${A}/fuzzcover.json"
[ "$(j "${A}/fuzzcover.json" '.[] | select(.dir=="geo") | .uncovered | join(",")')" = "Uncovered" ] || fail "geo uncovered: $(j "${A}/fuzzcover.json" '.[] | select(.dir=="geo")')"
[ "$(j "${A}/fuzzcover.json" '.[] | select(.dir=="geo") | [.functions[] | .name + ":" + (.mapped|tostring) + ":" + (.fuzzed_by|join("+"))] | join(" ")')" = "Helper:false: Covered:true:FuzzCovered Uncovered:true:" ] || fail "geo functions: $(j "${A}/fuzzcover.json" '.[] | select(.dir=="geo") | .functions')"
[ "$(j "${A}/fuzzcover.json" '.[] | select(.dir=="geo") | .property_files | join(",")')" = "geo/geo_test.go" ] || fail "quick.Check not detected"
[ "$(j "${A}/fuzzcover.json" '[.[] | .dir + "=" + (.fuzz_targets|join("+"))] | join(" ")')" = "auth=FuzzAllowed crash=FuzzParse geo=FuzzCovered" ] || fail "targets: $(j "${A}/fuzzcover.json" '[.[] | .fuzz_targets]')"

echo "== per-PR fuzz: crash/ yields a crasher under testdata/fuzz/FuzzParse; corpus listing diff finds it"
list() { find . -path '*/testdata/fuzz/*' -type f | sed 's#^\./##' | sort; }
list > "${A}/before.txt"
: > "${A}/fuzz-run.txt"
for p in auth crash geo; do
  for t in $(j "${A}/fuzzcover.json" ".[] | select(.dir==\"${p}\") | .fuzz_targets[]"); do
    echo "${p} ${t}" >> "${A}/fuzz-run.txt"
    timeout 120 go test -run='^$' -fuzz="^${t}\$" -fuzztime=5s "./${p}" >> "${A}/go-fuzz.txt" 2>&1 || true
  done
done
list | comm -13 "${A}/before.txt" - > "${A}/crashers.txt"
{ [ "$(wc -l < "${A}/crashers.txt")" -eq 1 ] && grep -q '^crash/testdata/fuzz/FuzzParse/' "${A}/crashers.txt"; } || fail "crashers: $(cat "${A}/crashers.txt")"

echo "== go.py: brief fields, crasher reproduction, high-risk auth with no property, corpus hygiene"
for t in vet staticcheck nilaway errcheck; do echo 0 > "${A}/status/${t}"; : > "${A}/go-${t}.txt"; done
echo 1 > "${A}/status/staticcheck"; printf 'geo/geo.go:15:1: SA4006 example\n' > "${A}/go-staticcheck.txt"
printf 'geo/geo.go\nauth/auth.go\ncrash/crash.go\n' > "${A}/changed-go.txt"
mkdir -p geo/testdata/fuzz/FuzzCovered
printf 'not a corpus file\n' > geo/testdata/fuzz/FuzzCovered/bad
printf 'geo/geo.go\ngeo/testdata/fuzz/FuzzNope/abc\ngeo/testdata/fuzz/FuzzCovered/bad\n' > "${A}/changed.txt"
python3 -I "${ACT}/go.py" --art "${A}" > "${A}/go.log"
[ "$(j "${A}/go.json" '[.vet, .staticcheck, .nilaway, .staticcheck_lines, .fuzz_targets, (.crashers|length), .property_files] | join(",")')" = "0,1,0,1,3,1,1" ] || fail "brief fields: $(cat "${A}/go.json")"
j "${A}/go.json" '.crasher_details[0].reproduce' | grep -qE "^go test -run='\^FuzzParse/[0-9a-f]+\\$' \./crash$" || fail "reproduce: $(j "${A}/go.json" '.crasher_details[0].reproduce')"
[ "$(j "${A}/go.json" '.high_risk_without_property | join(",")')" = "auth" ] || fail "auth without property: $(j "${A}/go.json" .high_risk_without_property)"
[ "$(j "${A}/go.json" '.uncovered | map(.name) | join(",")')" = "Uncovered" ] || fail "uncovered"
[ "$(j "${A}/go.json" '.hygiene | length')" = "2" ] || fail "hygiene: $(j "${A}/go.json" .hygiene)"
j "${A}/go.json" '.hygiene[0]' | grep -q 'no Fuzz target FuzzNope in package geo' || fail "hygiene target"
j "${A}/go.json" '.hygiene[1]' | grep -q 'not a go test fuzz v1 corpus file' || fail "hygiene header"

echo "== gate: crasher and uncovered block at baseline; staticcheck, property, hygiene advisory until standard"
summary "${A}" --gate
[ "${rc}" -eq 1 ] || fail "baseline must block: $(cat "${A}/summary.log")"
grep -q 'FAIL: 1 Go fuzz crasher(s): a concrete failing input exists' "${A}/summary.log" || fail "crasher gate"
grep -q 'FAIL: 1 exported function(s) on mapped paths with no Fuzz\* target' "${A}/summary.log" || fail "uncovered gate"
grep -q 'warn: staticcheck reported 1 finding(s) in changed packages' "${A}/summary.log" || fail "staticcheck advisory"
grep -q 'warn: 1 high-risk package(s) with no rapid/quick property' "${A}/summary.log" || fail "property advisory"
grep -q 'warn: 2 corpus-hygiene violation(s) under testdata/fuzz' "${A}/summary.log" || fail "hygiene advisory"
grep -q "^| \`crash/testdata/fuzz/FuzzParse/" "${A}/verify-brief.md" || fail "crasher row in brief"
[ "$(j "${A}/summary.json" '[.tool, .go_vet, .go_crashers, .go_fuzz_targets, .bare_high_risk] | join(",")')" = "verify-go,0,1,3,1" ] || fail "summary.json: $(cat "${A}/summary.json")"
summary "${A}" --gate --tier standard
[ "$(j "${A}/summary.json" '.gate.fail | length')" = "5" ] || fail "standard fail count: $(j "${A}/summary.json" .gate.fail)"

echo "== gate: go vet findings always block"
B="${TMP}/vet"; mkdir -p "${B}"
jq '.vet = 2 | .vet_lines = 1 | .crashers = [] | .crasher_details = [] | .uncovered = [] | .hygiene = [] | .high_risk_without_property = [] | .staticcheck = 0' "${A}/go.json" > "${B}/go.json"
summary "${B}" --gate
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: go vet reported findings' "${B}/summary.log"; } || fail "vet gate: $(cat "${B}/summary.log")"

echo "== gremlins: score excludes not viable; threshold gates"
cp "${FIX}/gremlins.json" "${B}/gremlins.json"
jq '.vet = 0' "${B}/go.json" > "${B}/g" && mv "${B}/g" "${B}/go.json"
summary "${B}" --gate --tier standard --mutation-threshold 50
{ [ "${rc}" -eq 0 ] && [ "$(j "${B}/summary.json" '.mutation_score == 60')" = "true" ]; } || fail "score: $(j "${B}/summary.json" .mutation_score) $(cat "${B}/summary.log")"
grep -q 'warn: 1 surviving mutant(s)' "${B}/summary.log" || fail "lived advisory"
summary "${B}" --gate --tier standard --mutation-threshold 75
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: mutation score 60.0% under the 75.0% threshold' "${B}/summary.log"; } || fail "threshold"

echo "all verify-go checks passed"
