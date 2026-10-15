#!/usr/bin/env bash
# Checks the fuzz composite's driver against the fixture targets: the python
# atheris targets (one plants a crash on "{!", one is clean) and the Go fuzz
# functions (same shape), each for a few seconds. Needs python3 with atheris
# (FUZZ_PYTHON, default: a venv created here), go and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
DRIVER="${ROOT}/.github/actions/fuzz/fuzz.py"
FIX="${HERE}/fixtures"
DURATION="${FUZZ_DURATION:-20s}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${FUZZ_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "atheris==3.1.0"
  FUZZ_PYTHON="${TMP}/env/bin/python"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <workdir> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  (cd "$2" && GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${DRIVER}" --crash-dir "${TMP}/$1.crashes" --output "${TMP}/$1.json" --python "${FUZZ_PYTHON}" "${@:3}") > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
status() { jq -r --arg t "$2" '.results[] | select(.target == $t) | .status' "${TMP}/$1.json"; }

echo "== python: fuzz_parse.py crashes on {!, fuzz_clean.py does not"
run py "${FIX}/python" --runtime python --targets fuzz_parse.py,fuzz_clean.py --duration "${DURATION}" --corpus-dir "${TMP}/corpus"
[ "${rc}" -eq 1 ] || fail "python rc ${rc}: $(tail -20 "${TMP}/py.log")"
[ "$(status py fuzz_parse.py)" = "crash" ] || fail "fuzz_parse.py should crash: $(jq -c .results "${TMP}/py.json")"
[ "$(status py fuzz_clean.py)" = "ok" ] || fail "fuzz_clean.py should be ok"
CRASH="$(jq -r '.results[0].crashes[0].file' "${TMP}/py.json")"
[ "$(head -c 2 "${CRASH}")" = "{!" ] || fail "crash input should start with {!: $(xxd "${CRASH}" | head -1)"
grep -q "^::error title=fuzz fuzz_parse.py::crash input crash-[0-9a-f]* (sha256 [0-9a-f]\{12\})" "${TMP}/py.log" || fail "crash annotation: $(grep '::error' "${TMP}/py.log")"
grep -q "^## Fuzz (python): 2 target(s) x ${DURATION}, 1 crash input(s), 1 crashing target(s)" "${TMP}/py.summary" || fail "summary: $(head -1 "${TMP}/py.summary")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| `fuzz_clean.py` | ok | none |' "${TMP}/py.summary" || fail "clean row"
[ "$(grep '^crash-count=' "${TMP}/py.out" | cut -d= -f2)" = "1" ] || fail "crash-count output"
[ "$(grep '^crashing-targets=' "${TMP}/py.out" | cut -d= -f2)" = "fuzz_parse.py" ] || fail "crashing-targets output"
[ -n "$(ls "${TMP}/corpus/fuzz_parse")" ] || fail "corpus directory populated for the parse target"

echo "== go: FuzzParse crashes, FuzzClean does not; the crasher is copied out of testdata"
rm -rf "${FIX}/go/parse/testdata"  # a crasher left by an earlier run would fail on replay instead
run go "${FIX}/go" --runtime go --targets ./parse:FuzzParse,./parse:FuzzClean --duration "${DURATION}"
[ "${rc}" -eq 1 ] || fail "go rc ${rc}: $(tail -20 "${TMP}/go.log")"
[ "$(status go ./parse:FuzzParse)" = "crash" ] || fail "FuzzParse should crash: $(jq -c .results "${TMP}/go.json")"
[ "$(status go ./parse:FuzzClean)" = "ok" ] || fail "FuzzClean should be ok"
GO_CRASH="$(jq -r '.results[0].crashes[0].file' "${TMP}/go.json")"
[ -s "${GO_CRASH}" ] || fail "go crash input copied"
case "${GO_CRASH}" in */parse_FuzzParse/*) ;; *) fail "crash dir name: ${GO_CRASH}" ;; esac
grep -q '^go test fuzz v1' "${GO_CRASH}" || fail "go crash input format"

echo "== go: the committed crasher fails on replay and is reported as a crash too"
run replay "${FIX}/go" --runtime go --targets ./parse:FuzzParse --duration 3s
[ "$(status replay ./parse:FuzzParse)" = "crash" ] || fail "replayed crasher: $(jq -c .results "${TMP}/replay.json")"
rm -rf "${FIX}/go/parse/testdata"

echo "== a target that cannot run is an error, not a crash"
run bad "${FIX}/python" --runtime python --targets missing.py --duration 5s --corpus-dir "${TMP}/corpus"
[ "${rc}" -eq 1 ] || fail "missing target rc ${rc}"
[ "$(status bad missing.py)" = "error" ] || fail "missing target status"
grep -q '^::error title=fuzz missing.py::target did not run cleanly' "${TMP}/bad.log" || fail "error annotation"

echo "== duration parsing"
run dur "${FIX}/python" --runtime python --targets fuzz_clean.py --duration 10x
grep -q 'duration must look like 30s, 10m or 1h' "${TMP}/dur.log" || fail "duration error"

echo "all fuzz checks passed"
