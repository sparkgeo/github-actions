#!/usr/bin/env bash
# Checks the verify-ts composite's scripts: the brief's tsc/fast-check/schema
# census (ts.py) with risk from verify-map.json and from the fallback globs,
# the boundary-contract AST check (entrypoints.mjs), the XState path runner on
# a good, a broken and an unbounded machine, the fallback typescript-eslint
# config, Stryker's score from a recorded mutation.json, and the gate rules
# (summary.py). Needs node, python3, jq, git and the example project's
# node_modules (docs/examples/verify/ts; install it first, scripts disabled).
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ACT="${ROOT}/.github/actions/verify-ts"
FIX="${HERE}/fixtures"
EXAMPLE="${ROOT}/docs/examples/verify/ts"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
[ -d "${EXAMPLE}/node_modules/typescript" ] || { echo "FAIL: install ${EXAMPLE} first (npm ci --ignore-scripts)" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }
summary() {  # <art> [args]; sets rc
  set +e
  GITHUB_OUTPUT="$1/out.txt" python3 -I "${ACT}/summary.py" --art "$1" "${@:2}" > "$1/summary.log" 2>&1
  rc=$?
  set -e
}

echo "== ts.py: brief fields, errors in changed files only, risk from verify-map.json"
A="${TMP}/ts"; mkdir -p "${A}"
cp "${FIX}/tsc/tsc.txt" "${FIX}/tsc/changed-ts.txt" "${A}/"
cd "${EXAMPLE}"
python3 -I "${ACT}/ts.py" --art "${A}" --tsc-rc 2 --map "${FIX}/tsc/verify-map.json" > "${A}/ts.log"
[ "$(j "${A}/ts.json" '[.tsc, .tsc_errors_all, .tsc_errors_changed, .changed, .test_files, .schema_files] | join(",")')" = "2,3,2,3,1,1" ] || fail "brief fields: $(cat "${A}/ts.json")"
[ "$(j "${A}/ts.json" '.property_files | join(",")')" = "test/bbox.property.test.ts" ] || fail "property files"
[ "$(j "${A}/ts.json" '.high_risk | join(",")')" = "src/bbox.ts" ] || fail "high risk from map: $(j "${A}/ts.json" .high_risk)"
[ "$(j "${A}/ts.json" '.mapped | join(",")')" = "src/bbox.ts,src/upload.machine.ts" ] || fail "mapped"
[ "$(j "${A}/ts.json" '.high_risk_without_property | length')" = "0" ] || fail "bbox has a fast-check property"
grep -q '^  tsc rc=2: 2 error(s) in changed files (3 total); 1/1 changed test file(s) use fast-check; 1 changed file(s) declare schemas; 0 high-risk' "${A}/ts.log" || fail "ts line: $(cat "${A}/ts.log")"

echo "== ts.py: fallback globs; a high-risk module no fast-check test imports"
python3 -I "${ACT}/ts.py" --art "${A}" --tsc-rc 0 --high-risk-globs '**/src/**' > /dev/null
[ "$(j "${A}/ts.json" '.high_risk_without_property | join(",")')" = "src/upload.machine.ts" ] || fail "without property: $(j "${A}/ts.json" .high_risk_without_property)"
[ "$(j "${A}/ts.json" '.mapped | join(",")')" = "src/bbox.ts,src/upload.machine.ts" ] || fail "fallback mapped = high risk"

echo "== entrypoints.mjs: validated, unvalidated, typed and untyped exported functions"
B="${TMP}/entry"; mkdir -p "${B}"
echo "${FIX}/entry/handlers.ts" > "${B}/files.txt"
node "${ACT}/entrypoints.mjs" "${EXAMPLE}" "${B}/files.txt" "${B}/entrypoints.json" > "${B}/entry.log"
[ "$(j "${B}/entrypoints.json" '.[0].unvalidated | join(",")')" = "createUnvalidated,untypedArrow" ] || fail "unvalidated: $(cat "${B}/entrypoints.json")"
[ "$(j "${B}/entrypoints.json" '[.[0].functions[] | .name + "=" + (.validated|tostring)] | join(" ")')" = "createValidated=true createUnvalidated=false typed=false untypedArrow=false safeArrow=true" ] || fail "functions: $(j "${B}/entrypoints.json" '.[0].functions')"
[ "$(j "${B}/entrypoints.json" '.[0].branded')" = "1" ] || fail "branded count"
grep -q '^  1 file(s) checked, 5 exported function(s), 2 unvalidated entry point(s)$' "${B}/entry.log" || fail "entry line: $(cat "${B}/entry.log")"
echo "src/bbox.ts" > "${B}/example.txt"
node "${ACT}/entrypoints.mjs" "${EXAMPLE}" "${B}/example.txt" "${B}/example.json" > /dev/null
[ "$(j "${B}/example.json" '.[0].unvalidated | length')" = "0" ] || fail "example normalizeBbox must count as validated: $(cat "${B}/example.json")"

echo "== xstate-paths: good machine passes, a throwing entry action fails its path, orphan state unreached, unbounded context value-only"
P="${TMP}/proj"; mkdir -p "${P}/src" "${P}/.verify-ts"
ln -s "${EXAMPLE}/node_modules" "${P}/node_modules"
cp "${EXAMPLE}/package.json" "${EXAMPLE}/tsconfig.json" "${P}/"
cp "${FIX}/machines/"*.ts "${P}/src/"
cp "${ACT}/xstate-paths.test.mjs" "${P}/.verify-ts/"
printf 'export default { test: { include: [".verify-ts/*.test.mjs"], root: process.cwd() } };\n' > "${P}/.verify-ts/vitest.config.mjs"
cd "${P}"
VERIFY_TS_MACHINES="[\"${P}/src/good.machine.ts\",\"${P}/src/broken.machine.ts\",\"${P}/src/counter.machine.ts\"]" VERIFY_TS_XSTATE_OUT="${P}/xstate.json" VERIFY_TS_XSTATE_LIMIT=50 \
  node_modules/.bin/vitest run --config .verify-ts/vitest.config.mjs > "${P}/xstate.txt" 2>&1 || true
[ -s "${P}/xstate.json" ] || fail "no xstate.json: $(tail -30 "${P}/xstate.txt")"
[ "$(j "${P}/xstate.json" '.[] | select(.machine=="doorMachine") | [.paths, .executed, (.failures|length), (.unreached|length), .bound] | join(",")')" = "3,3,0,0,context" ] || fail "door: $(j "${P}/xstate.json" '.[] | select(.machine=="doorMachine")')"
[ "$(j "${P}/xstate.json" '.[] | select(.machine=="jobMachine") | .failures | length')" -ge 1 ] || fail "job failure: $(j "${P}/xstate.json" '.[] | select(.machine=="jobMachine")')"
j "${P}/xstate.json" '.[] | select(.machine=="jobMachine") | .failures[0].path' | grep -q 'CRASH' || fail "failing path names CRASH"
[ "$(j "${P}/xstate.json" '.[] | select(.machine=="jobMachine") | .unreached | join(",")')" = "orphan" ] || fail "orphan unreached"
[ "$(j "${P}/xstate.json" '.[] | select(.machine=="counterMachine") | .bound')" = "value-only" ] || fail "counter bound: $(j "${P}/xstate.json" '.[] | select(.machine=="counterMachine")')"

echo "== eslint fallback config: typescript-eslint strict flags any and unsafe returns"
cp "${FIX}/entry/handlers.ts" "${P}/src/"
cp "${ACT}/eslint.verify.config.mjs" "${P}/.verify-ts/eslint.config.mjs"
set +e
node_modules/.bin/eslint --config .verify-ts/eslint.config.mjs --no-warn-ignored --format json --output-file "${P}/eslint.json" src/handlers.ts
erc=$?
set -e
[ "${erc}" -eq 1 ] || fail "eslint rc ${erc}"
j "${P}/eslint.json" '[.[].messages[].ruleId] | join(",")' | grep -q '@typescript-eslint/no-explicit-any' || fail "no-explicit-any not reported: $(j "${P}/eslint.json" '[.[].messages[].ruleId]')"

echo "== summary/gate: baseline advisory, standard blocking"
C="${TMP}/gate"; mkdir -p "${C}/reports"
cp "${A}/ts.json" "${C}/"   # fallback run: upload.machine.ts high-risk with no property
jq '.tsc_errors_changed = 2' "${C}/ts.json" > "${C}/t" && mv "${C}/t" "${C}/ts.json"
jq '.[0].file = "src/bbox.ts"' "${B}/entrypoints.json" > "${C}/entrypoints.json"
summary "${C}" --gate
[ "${rc}" -eq 0 ] || fail "baseline must pass: $(cat "${C}/summary.log")"
grep -q 'warn: 2 TypeScript error(s) in changed files under the strictest flags' "${C}/summary.log" || fail "tsc advisory"
grep -q 'warn: 2 exported entry point(s) on mapped paths take untrusted input without a schema parse' "${C}/summary.log" || fail "entry advisory: $(cat "${C}/summary.log")"
grep -q 'warn: 1 high-risk file(s) with no fast-check property' "${C}/summary.log" || fail "property advisory"
summary "${C}" --gate --strict
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: 2 TypeScript error(s)' "${C}/summary.log"; } || fail "strict tsc must block"
summary "${C}" --gate --tier standard
{ [ "${rc}" -eq 1 ] && [ "$(j "${C}/summary.json" '.gate.fail | length')" = "3" ]; } || fail "standard: $(cat "${C}/summary.log")"
grep -q '| `src/bbox.ts:10` `createUnvalidated` | body |' "${C}/verify-brief.md" || fail "entry table: $(grep createUnvalidated "${C}/verify-brief.md")"
[ "$(j "${C}/summary.json" '[.tool, .ts_errors_changed, .ts_property_files, .unvalidated_entry_points, .bare_high_risk] | join(",")')" = "verify-ts,2,1,2,1" ] || fail "summary.json: $(cat "${C}/summary.json")"

echo "== summary/gate: ESLint errors and XState failures always block"
D="${TMP}/gate2"; mkdir -p "${D}"
echo '{"tsc": 0, "tsc_errors_all": 0, "tsc_errors_changed": 0, "changed": 1, "test_files": 0, "property_files": [], "schema_files": 0, "high_risk": [], "mapped": [], "high_risk_without_property": []}' > "${D}/ts.json"
cp "${P}/eslint.json" "${D}/eslint.json"
summary "${D}" --gate --eslint-rc 1
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: .* ESLint error(s) in changed files' "${D}/summary.log"; } || fail "eslint must block: $(cat "${D}/summary.log")"
rm "${D}/eslint.json"; cp "${P}/xstate.json" "${D}/xstate.json"
summary "${D}" --gate --tier standard
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: .* XState path(s) failed when executed' "${D}/summary.log" && grep -q 'warn: 1 XState state(s) unreached' "${D}/summary.log"; } || fail "xstate gate: $(cat "${D}/summary.log")"
grep -q 'counterMachine`: traversal exceeded the state limit' "${D}/verify-brief.md" || fail "value-only note"

echo "== summary/gate: Stryker score from mutation.json (errors excluded) and threshold"
E="${TMP}/gate3"; mkdir -p "${E}/reports"
cp "${D}/ts.json" "${E}/"; cp "${FIX}/mutation.json" "${E}/reports/mutation.json"
summary "${E}" --gate --tier standard --mutation-threshold 50
{ [ "${rc}" -eq 0 ] && [ "$(j "${E}/summary.json" '.mutation_score == 60')" = "true" ]; } || fail "score: $(j "${E}/summary.json" .mutation_score) $(cat "${E}/summary.log")"
grep -q '^mutation-score=60.0$' "${E}/out.txt" || fail "output: $(cat "${E}/out.txt")"
summary "${E}" --gate --tier standard --mutation-threshold 80
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: mutation score 60.0% under the 80.0% threshold' "${E}/summary.log"; } || fail "threshold: $(cat "${E}/summary.log")"

echo "all verify-ts checks passed"
