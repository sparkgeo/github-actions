#!/usr/bin/env bash
# Checks lean.py (shared by the lean and kani composites) on recorded output:
# lake build --wfail passing, failing on a sorry and failing on a false
# statement; cargo kani with one verified and one failing harness; the brief
# and the gate. The CI job runs Lean and Kani live on the same fixtures and
# the Mathlib example. Needs python3 and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PY="${ROOT}/.github/actions/lean/lean.py"
LOGS="${HERE}/fixtures/logs"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }
brief() {  # <art> ; sets rc
  set +e
  GITHUB_OUTPUT="$1/out.txt" python3 -I "${PY}" brief --art "$1" --gate > "$1/brief.log" 2>&1
  rc=$?
  set -e
}

echo "== lean: a passing build"
A="${TMP}/ok"; mkdir -p "${A}"
python3 -I "${PY}" lean --log "${LOGS}/ok.txt" --rc 0 --root tests/verify-lean/fixtures/ok/ --output "${A}/lean.json" > /dev/null
[ "$(j "${A}/lean.json" '.outcome + ":" + (.issues | length | tostring)')" = "success:0" ] || fail "ok: $(cat "${A}/lean.json")"
brief "${A}"
{ [ "${rc}" -eq 0 ] && grep -q '^`lake build --wfail`: proven (0 error(s), 0 unfinished proof(s))$' "${A}/verify-brief.md"; } || fail "ok brief: $(cat "${A}/verify-brief.md")"
[ "$(j "${A}/summary.json" '[.tool, .lean, (.kani // "null")] | join(",")')" = "verify-lean,success,null" ] || fail "ok summary"

echo "== lean: sorry fails under --wfail and is reported as an unfinished proof"
B="${TMP}/sorry"; mkdir -p "${B}"
python3 -I "${PY}" lean --log "${LOGS}/sorry.txt" --rc 1 --root tests/verify-lean/fixtures/sorry/ --output "${B}/lean.json" > "${B}/parse.log"
[ "$(j "${B}/lean.json" '.issues | map(.kind + "@" + .file + ":" + (.line|tostring)) | join(",")')" = "sorry@tests/verify-lean/fixtures/sorry/Fixture.lean:2" ] || fail "sorry: $(cat "${B}/lean.json")"
grep -q '^::error file=tests/verify-lean/fixtures/sorry/Fixture.lean,line=2,col=8,title=unfinished proof (sorry)::' "${B}/parse.log" || fail "sorry annotation"
brief "${B}"
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: Lean build failed or a proof is unfinished (sorry)' "${B}/brief.log"; } || fail "sorry gate"
[ "$(j "${B}/summary.json" '.lean + ":" + (.unverified|tostring)')" = "failure:1" ] || fail "sorry summary"

echo "== lean: a false statement is an error"
C="${TMP}/false"; mkdir -p "${C}"
python3 -I "${PY}" lean --log "${LOGS}/false.txt" --rc 1 --output "${C}/lean.json" > /dev/null
[ "$(j "${C}/lean.json" '.issues[0] | .kind + ":" + .message')" = "error:omega could not prove the goal:" ] || fail "false: $(cat "${C}/lean.json")"

echo "== lean: an unpositioned warning fails under --wfail and is reported as the cause"
G="${TMP}/warn"; mkdir -p "${G}"
python3 -I "${PY}" lean --log "${LOGS}/module-warning.txt" --rc 1 --root docs/examples/verify/lean/ --output "${G}/lean.json" > /dev/null
[ "$(j "${G}/lean.json" '.issues | map(.kind + "@" + .file + ":" + (.line|tostring)) | join(",")')" = "error@docs/examples/verify/lean/Tiles/Column.lean:1" ] || fail "module warning: $(cat "${G}/lean.json")"
j "${G}/lean.json" '.issues[0].message' | grep -q '^warning (fails under --wfail): imports `Mathlib`' || fail "module warning message"

echo "== kani: one verified harness, one overflow"
D="${TMP}/kani"; mkdir -p "${D}"
python3 -I "${PY}" kani --log "${LOGS}/kani.txt" --rc 1 --crate tests/verify-lean/fixtures/kani --output "${D}/kani-crate.json" > "${D}/parse.log"
[ "$(j "${D}/kani-crate.json" '[.verified, .failures, (.harnesses | map(.name + "=" + .result) | join("+"))] | join(",")')" = "1,1,proofs::tile_index_no_overflow=failed+proofs::quadkey_len_bounded=successful" ] || fail "kani: $(cat "${D}/kani-crate.json")"
[ "$(j "${D}/kani-crate.json" '.failed_checks[0].description')" = "attempt to multiply with overflow" ] || fail "kani check"
grep -q '^::error file=tests/verify-lean/fixtures/kani/Cargo.toml,title=Kani failure::tile_index.assertion.2: attempt to multiply with overflow$' "${D}/parse.log" || fail "kani annotation"
brief "${D}"
{ [ "${rc}" -eq 1 ] && grep -q 'FAIL: Kani found a reachable panic or failed harness' "${D}/brief.log"; } || fail "kani gate"
grep -q '^| `tests/verify-lean/fixtures/kani` | 1 | \*\*1\*\* |$' "${D}/verify-brief.md" || fail "kani row"
[ "$(j "${D}/summary.json" '(.lean // "null") + ":" + .kani')" = "null:failure" ] || fail "kani summary"
grep -q '^kani=failure$' "${D}/out.txt" || fail "outputs"

echo "== kani: non-zero exit with no harness result is a failure"
printf 'error: could not compile `kani-fixture`\n' > "${TMP}/broken.txt"
python3 -I "${PY}" kani --log "${TMP}/broken.txt" --rc 101 --crate c --output "${TMP}/kani-broken.json" > /dev/null
[ "$(j "${TMP}/kani-broken.json" '.failures')" = "1" ] || fail "broken"

echo "all lean checks passed"
