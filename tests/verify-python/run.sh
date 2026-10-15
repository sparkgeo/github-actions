#!/usr/bin/env bash
# Checks the verify-python composite's scripts: the contract census (every
# contract spelling, private functions skipped, high risk from the fallback
# globs and from verify-map.json, opaque C-extension boundaries), the
# CrossHair parser on a real counterexample and on the example module's
# confirmed postconditions, diffbehavior on a sample refactor, the summary
# counters and the gate (counterexample, mypy, properties, strict high-risk,
# tier standard, mutation threshold) and mutmut on the example. Needs a venv
# with crosshair-tool, icontract, deal, hypothesis, pytest, mypy and mutmut
# (VERIFY_BIN = its bin directory; created here when unset), git and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ACT="${ROOT}/.github/actions/verify-python"
FIX="${HERE}/fixtures"
EXAMPLE="${ROOT}/docs/examples/verify/python"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${VERIFY_BIN:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check \
    "crosshair-tool==0.0.111" "icontract==2.7.3" "deal==4.24.6" "hypothesis==6.169.3" "pytest==9.1.1" "mypy==2.4.0" "mutmut==3.8.0"
  VERIFY_BIN="${TMP}/env/bin"
fi
PY="${VERIFY_BIN}/python"

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }
summary() {  # <art> [args]; sets rc, writes <art>/summary.json
  set +e
  GITHUB_OUTPUT="$1/out.txt" "${PY}" -I "${ACT}/summary.py" --art "$1" "${@:2}" > "$1/summary.log" 2>&1
  rc=$?
  set -e
}

echo "== census: every contract spelling, private skipped, fallback high risk, opaque boundaries"
A="${TMP}/census"; mkdir -p "${A}"
cd "${ROOT}"
printf '%s\n' tests/verify-python/fixtures/census/contracted.py tests/verify-python/fixtures/census/auth/session.py tests/verify-python/fixtures/census/opaque.py tests/verify-python/fixtures/census/missing.py > "${A}/changed.txt"
"${PY}" -I "${ACT}/census.py" --changed "${A}/changed.txt" --output "${A}/census.json" > "${A}/census.log"
grep -q '^  10 public function(s) changed, 5 contracted, 2 uncontracted on high-risk paths, 3 crossing an opaque boundary$' "${A}/census.log" || fail "census line: $(cat "${A}/census.log")"
[ "$(j "${A}/census.json" '[.[] | select(.file | endswith("contracted.py")) | .name + "=" + (.contracts | join("+"))] | join(" ")')" = "with_icontract=ensure+require with_deal=post+pre with_pep316=PEP316 with_assert=assert" ] || fail "contract kinds: $(j "${A}/census.json" '.[] | .name')"
[ "$(j "${A}/census.json" '[.[] | select(.file | endswith("session.py")) | .high_risk] | all')" = "true" ] || fail "auth path not high risk"
[ "$(j "${A}/census.json" '[.[] | select(.file | endswith("contracted.py")) | .high_risk] | any')" = "false" ] || fail "contracted.py high risk without a map"
[ "$(j "${A}/census.json" '[.[] | select(.file | endswith("opaque.py")) | .name + "=" + (.opaque | join("+"))] | join(" ")')" = "buffer_metres=shapely reproject=pyproj mean_of=numpy pure=" ] || fail "opaque: $(j "${A}/census.json" '.[] | select(.file | endswith("opaque.py"))')"

echo "== census: risk comes from verify-map.json when given"
"${PY}" -I "${ACT}/census.py" --changed "${A}/changed.txt" --map "${FIX}/census/verify-map.json" --output "${A}/census-map.json" > "${A}/census-map.log"
[ "$(j "${A}/census-map.json" '[.[] | select(.file | endswith("contracted.py")) | .high_risk] | all')" = "true" ] || fail "map risk not applied"
[ "$(j "${A}/census-map.json" '[.[] | select(.file | endswith("session.py")) | .high_risk] | any')" = "false" ] || fail "map low risk not applied"
grep -q '0 uncontracted on high-risk paths' "${A}/census-map.log" || fail "map census line: $(cat "${A}/census-map.log")"

echo "== crosshair: a false postcondition is a counterexample (rule crosshair.counterexample, error)"
B="${TMP}/cex"; mkdir -p "${B}/status"
cd "${FIX}/cex"
set +e
"${VERIFY_BIN}/crosshair" check --analysis_kind=asserts,PEP316,icontract,deal --per_path_timeout 3 --per_condition_timeout 45 --report_all bad.py > "${B}/crosshair.txt" 2> "${B}/crosshair.err"
echo $? > "${B}/status/crosshair"
set -e
sed -i "s|^${PWD}/||" "${B}/crosshair.txt"
"${PY}" -I "${ACT}/crosshair.py" --text "${B}/crosshair.txt" --sarif "${B}/crosshair.sarif" --json "${B}/crosshair.json" > "${B}/parse.log"
[ "$(j "${B}/crosshair.json" '.counterexamples | length')" = "1" ] || fail "counterexamples: $(cat "${B}/crosshair.txt")"
[ "$(j "${B}/crosshair.json" '.counterexamples[0] | .file + ":" + (.line|tostring)')" = "bad.py:5" ] || fail "counterexample location: $(j "${B}/crosshair.json" '.counterexamples[0]')"
[ "$(j "${B}/crosshair.sarif" '.runs[0].results[] | select(.ruleId == "crosshair.counterexample") | .level')" = "error" ] || fail "sarif rule"
[ "$(j "${B}/crosshair.sarif" '.runs[0].tool.driver.rules | map(.id) | join(",")')" = "crosshair.counterexample,crosshair.not-verified" ] || fail "sarif rules"
grep -q '^  1 counterexample(s), ' "${B}/parse.log" || fail "parse line: $(cat "${B}/parse.log")"
summary "${B}" --gate
[ "${rc}" -eq 1 ] || fail "counterexample must block: $(cat "${B}/summary.log")"
grep -q '^  FAIL: 1 CrossHair counterexample(s): a stated contract is false$' "${B}/summary.log" || fail "gate text: $(cat "${B}/summary.log")"
[ "$(j "${B}/summary.json" '.counterexamples, .tool, .strict' | paste -sd,)" = "1,verify-python,false" ] || fail "summary.json: $(cat "${B}/summary.json")"
grep -q '^| `bad.py:5` | false when calling inc(' "${B}/verify-brief.md" || fail "brief counterexample row: $(grep 'bad.py' "${B}/verify-brief.md")"

echo "== crosshair: the example module's child() postconditions are confirmed over all paths"
C="${TMP}/example"; mkdir -p "${C}/status"
cd "${EXAMPLE}"
echo tiles/quadkey.py > "${C}/changed-py.txt"
"${PY}" -I "${ACT}/census.py" --changed "${C}/changed-py.txt" --output "${C}/census.json" > "${C}/census.log"
grep -q '^  4 public function(s) changed, 4 contracted, 0 uncontracted' "${C}/census.log" || fail "example census: $(cat "${C}/census.log")"
set +e
PYTHONPATH="${PWD}" "${VERIFY_BIN}/crosshair" check --analysis_kind=asserts,PEP316,icontract,deal --per_path_timeout 3 --per_condition_timeout 45 --report_all tiles/quadkey.py > "${C}/crosshair.txt" 2> "${C}/crosshair.err"
echo $? > "${C}/status/crosshair"
set -e
sed -i "s|^${PWD}/||" "${C}/crosshair.txt"
"${PY}" -I "${ACT}/crosshair.py" --text "${C}/crosshair.txt" --sarif "${C}/crosshair.sarif" --json "${C}/crosshair.json" > "${C}/parse.log"
[ "$(j "${C}/crosshair.json" '.counterexamples | length')" = "0" ] || fail "example counterexample: $(j "${C}/crosshair.json" '.counterexamples')"
[ "$(j "${C}/crosshair.json" '.exhausted | length')" -ge 3 ] || fail "child() not confirmed: $(cat "${C}/crosshair.txt")"
[ "$(j "${C}/crosshair.json" '.unverified | length')" -ge 1 ] || fail "expected encode/decode not confirmed"
"${PY}" -m mypy --strict tiles > "${C}/mypy.txt" 2>&1 || fail "example mypy: $(cat "${C}/mypy.txt")"
"${PY}" -m pytest -q -m property -p no:cacheprovider tests > "${C}/pytest.txt" 2>&1 || fail "example properties: $(tail -5 "${C}/pytest.txt")"
grep -q '3 passed' "${C}/pytest.txt" || fail "expected 3 properties: $(tail -1 "${C}/pytest.txt")"

echo "== gate: tiles is a high-risk path; not confirmed is advisory at baseline and blocks at standard"
summary "${C}" --gate --mypy-rc 0 --pytest-rc 0
[ "${rc}" -eq 0 ] || fail "baseline must pass: $(cat "${C}/summary.log")"
grep -q 'warn: .* contract(s) not confirmed within budget' "${C}/summary.log" || fail "advisory missing: $(cat "${C}/summary.log")"
[ "$(j "${C}/summary.json" '.exhausted >= 3 and .unverified >= 1 and .changed_public == 4 and .contracted == 4 and .bare_high_risk == 0 and .mypy == 0 and .properties == 0')" = "true" ] || fail "example summary: $(cat "${C}/summary.json")"
grep -q '^counterexamples=0$' "${C}/out.txt" || fail "outputs: $(cat "${C}/out.txt")"
summary "${C}" --gate --tier standard
[ "${rc}" -eq 1 ] || fail "standard must block on an unconfirmed high-risk contract: $(cat "${C}/summary.log")"
grep -q 'not confirmed within budget (tier standard)' "${C}/summary.log" || fail "standard text: $(cat "${C}/summary.log")"
summary "${C}" --gate --mypy-rc 1
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: mypy --strict reported errors' "${C}/summary.log"; } || fail "mypy must block"
summary "${C}" --gate --pytest-rc 1
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: pytest -m property failed' "${C}/summary.log"; } || fail "property failure must block"
summary "${C}" --gate --pytest-rc 5
[ "${rc}" -eq 0 ] || fail "no property tests collected is not a failure"
grep -q '^no property tests collected$' "${C}/verify-brief.md" || fail "brief properties line"
summary "${C}" --mypy-rc 1
[ "${rc}" -eq 0 ] || fail "without --gate nothing blocks"

echo "== gate: uncontracted high-risk functions warn by default and block with --strict"
summary "${A}"
{ [ "${rc}" -eq 0 ] && grep -q 'warn: 2 changed public function(s) on high-risk paths with no contract' "${A}/summary.log"; } || fail "bare advisory: $(cat "${A}/summary.log")"
summary "${A}" --gate --strict
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: 2 changed public function(s) on high-risk paths with no contract' "${A}/summary.log"; } || fail "bare strict: $(cat "${A}/summary.log")"
grep -q '3 function(s) call into a C extension' "${A}/verify-brief.md" || fail "opaque note missing"
grep -q '| `tests/verify-python/fixtures/census/opaque.py:8` `buffer_metres` | PEP316 |  | shapely |' "${A}/verify-brief.md" || fail "opaque column: $(grep buffer_metres "${A}/verify-brief.md")"
[ "$(j "${A}/summary.json" '.strict')" = "true" ] || fail "strict flag"

echo "== diffbehavior: an equivalent refactor agrees, a behaviour change differs, private functions skipped"
D="${TMP}/refactor"; mkdir -p "${D}/repo" "${D}/art"
cd "${D}/repo"
git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
cp "${FIX}/refactor/base_calc.py" calc.py && git add calc.py && git -c user.name=t -c user.email=t@t commit -q -m base
cp "${FIX}/refactor/head_calc.py" calc.py && git add calc.py && git -c user.name=t -c user.email=t@t commit -q -m head
echo calc.py > "${D}/art/changed-py.txt"
PYTHONPATH="${PWD}" "${PY}" -I "${ACT}/diffbehavior.py" --changed "${D}/art/changed-py.txt" --base HEAD~1 --crosshair "${VERIFY_BIN}/crosshair" --per-condition-timeout 20 --basecopy "${D}/basecopy" --output "${D}/art/diffbehavior.json" > "${D}/art/diff.log"
grep -q '^  2 function(s) compared, 1 differ$' "${D}/art/diff.log" || fail "diff line: $(cat "${D}/art/diff.log")"
[ "$(j "${D}/art/diffbehavior.json" '[.[] | .function + "=" + .verdict] | join(" ")')" = "double=agrees (within budget) total=differs" ] || fail "verdicts: $(cat "${D}/art/diffbehavior.json")"
[ -f "${D}/basecopy/base_calc.py" ] || fail "base copy not written"
mkdir -p "${D}/art/status"; echo 0 > "${D}/art/status/crosshair"; echo '{"counterexamples": [], "unverified": [], "exhausted": []}' > "${D}/art/crosshair.json"; echo '[]' > "${D}/art/census.json"
summary "${D}/art" --gate
{ [ "${rc}" -eq 0 ] && grep -q 'warn: 1 refactored function(s) differ from base on some input' "${D}/art/summary.log"; } || fail "differs is advisory: $(cat "${D}/art/summary.log")"
grep -q '| `calc.py` `total` | differs |' "${D}/art/verify-brief.md" || fail "diff table"
[ "$(j "${D}/art/summary.json" '.diff_differs')" = "1" ] || fail "diff_differs"

echo "== mutation: mutmut on the example's child(); score reported, threshold gates"
E="${TMP}/mut"; mkdir -p "${E}/proj" "${E}/art/status"
cp -r "${EXAMPLE}/tiles" "${EXAMPLE}/tests" "${EXAMPLE}/pyproject.toml" "${E}/proj/"
cd "${E}/proj"
timeout 180 "${VERIFY_BIN}/mutmut" run 'tiles.quadkey.x_child*' > "${E}/art/mutmut-run.txt" 2>&1 || fail "mutmut run: $(tail -5 "${E}/art/mutmut-run.txt")"
"${VERIFY_BIN}/mutmut" results > "${E}/art/mutmut-results.txt" 2>/dev/null || true
"${VERIFY_BIN}/mutmut" export-cicd-stats > /dev/null 2>&1 && cp mutants/mutmut-cicd-stats.json "${E}/art/"
[ "$(j "${E}/art/mutmut-cicd-stats.json" '.total')" -ge 10 ] || fail "mutants: $(cat "${E}/art/mutmut-cicd-stats.json")"
echo 0 > "${E}/art/status/crosshair"; echo '{"counterexamples": [], "unverified": [], "exhausted": []}' > "${E}/art/crosshair.json"; echo '[]' > "${E}/art/census.json"
summary "${E}/art" --gate --tier standard --mutation-threshold 50
[ "${rc}" -eq 0 ] || fail "score over threshold must pass: $(cat "${E}/art/summary.log")"
score="$(j "${E}/art/summary.json" '.mutation_score')"
[ "$(jq -n --argjson s "${score}" '$s > 50 and $s <= 100')" = "true" ] || fail "score ${score}"
grep -q "^Score ${score}%: " "${E}/art/verify-brief.md" || fail "brief score line: $(grep Score "${E}/art/verify-brief.md")"
grep -q "^mutation-score=${score}$" "${E}/art/out.txt" || fail "mutation-score output: $(cat "${E}/art/out.txt")"
summary "${E}/art" --gate --tier standard --mutation-threshold 100
{ [ "${rc}" -eq 1 ] && grep -q "FAIL: mutation score ${score}% under the 100.0% threshold" "${E}/art/summary.log"; } || fail "threshold must block: $(cat "${E}/art/summary.log")"

echo "all verify-python checks passed"
