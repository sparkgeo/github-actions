#!/usr/bin/env bash
# Checks the Gobra composite's script on recorded Gobra v26.02 logs: a false
# postcondition (verification), generics and an unresolvable import
# (unsupported), an impure call in a postcondition (typecheck), paths
# prefixed into the repository, a non-zero exit with no located error, and
# the brief and gate with and without fail-on-unsupported. The CI job runs
# the image live on the example and on fixtures/mod. Needs python3 and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PY="${ROOT}/.github/actions/gobra/gobra.py"
LOGS="${HERE}/fixtures/logs"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }
parse() {  # <log> <package> <rc> <art>
  python3 -I "${PY}" parse --log "${LOGS}/$1.txt" --package "$2" --rc "$3" --root "tests/verify-gobra/fixtures/mod/" --output "$4/gobra-$2.json" > "$4/$2.parse"
}

A="${TMP}/all"; mkdir -p "${A}"
echo "== parse: one category per recorded log"
parse bad bad 1 "${A}"
[ "$(j "${A}/gobra-bad.json" '.errors | map(.category + "@" + .file + ":" + (.line|tostring)) | join(",")')" = "verification@tests/verify-gobra/fixtures/mod/bad/bad.go:4" ] || fail "bad: $(cat "${A}/gobra-bad.json")"
[ "$(j "${A}/gobra-bad.json" '.errors[0].message')" = "Postcondition might not hold." ] || fail "bad message"
grep -q '^::error file=tests/verify-gobra/fixtures/mod/bad/bad.go,line=4,col=9,title=gobra verification::Postcondition might not hold.$' "${A}/bad.parse" || fail "bad annotation: $(cat "${A}/bad.parse")"
parse generic generic 1 "${A}"
[ "$(j "${A}/gobra-generic.json" '.errors | map(.category) | join(",")')" = "unsupported" ] || fail "generic: $(cat "${A}/gobra-generic.json")"
parse import imports 1 "${A}"
[ "$(j "${A}/gobra-imports.json" '.errors | map(.category) | join(",")')" = "unsupported" ] || fail "import: $(cat "${A}/gobra-imports.json")"
j "${A}/gobra-imports.json" '.errors[0].message' | grep -q "^Explicit qualifier could not be derived" || fail "import message keeps the reason, drops the file prefix"
parse purity purity 1 "${A}"
[ "$(j "${A}/gobra-purity.json" '.errors | map(.category) | join(",")')" = "typecheck,typecheck" ] || fail "purity: $(cat "${A}/gobra-purity.json")"

echo "== parse: non-zero exit with no located error is still an error"
B="${TMP}/oom"; mkdir -p "${B}"
printf 'java.lang.OutOfMemoryError: Java heap space\n' > "${B}/oom.txt"
python3 -I "${PY}" parse --log "${B}/oom.txt" --package big --rc 1 --output "${B}/gobra-big.json" > /dev/null
[ "$(j "${B}/gobra-big.json" '.errors[0].category + ":" + .errors[0].message')" = "typecheck:Gobra exited 1 without a located error (see the log)" ] || fail "oom: $(cat "${B}/gobra-big.json")"

echo "== brief and gate: verification and typecheck block; unsupported blocks only with --fail-on-unsupported"
run() {  # <art> [args]; sets rc
  set +e
  GITHUB_OUTPUT="$1/out.txt" python3 -I "${PY}" brief --art "$1" "${@:2}" > "$1/brief.log" 2>&1
  rc=$?
  set -e
}
run "${A}" --gate --fail-on-unsupported
[ "${rc}" -eq 1 ] || fail "gate rc ${rc}"
grep -q 'FAIL: 1 Gobra verification error(s): an annotated contract does not hold' "${A}/brief.log" || fail "verification gate: $(cat "${A}/brief.log")"
grep -q 'FAIL: 2 Gobra type-check error(s) in annotated packages' "${A}/brief.log" || fail "typecheck gate"
grep -q 'FAIL: 2 unsupported construct(s): those packages were not verified' "${A}/brief.log" || fail "unsupported gate"
[ "$(j "${A}/summary.json" '[.tool, .gobra, .packages, .unverified] | join(",")')" = "verify-gobra,1,4,2" ] || fail "summary.json: $(cat "${A}/summary.json")"
grep -q '^| `generic` | \*\*1 unsupported\*\* |$' "${A}/verify-brief.md" || fail "package row: $(grep generic "${A}/verify-brief.md")"
grep -q '^verification-errors=1$' "${A}/out.txt" || fail "outputs"
C="${TMP}/unsup"; mkdir -p "${C}"; cp "${A}/gobra-generic.json" "${C}/"
run "${C}" --gate
{ [ "${rc}" -eq 0 ] && grep -q 'warn: 1 unsupported construct(s)' "${C}/brief.log"; } || fail "unsupported advisory: $(cat "${C}/brief.log")"

echo "== brief: no package in scope"
D="${TMP}/none"; mkdir -p "${D}"
run "${D}" --gate
{ [ "${rc}" -eq 0 ] && [ "$(j "${D}/summary.json" '.gobra')" = "null" ]; } || fail "empty scope"
grep -q 'No changed package carries the `gobra` rung.' "${D}/verify-brief.md" || fail "empty brief"

echo "all gobra checks passed"
