#!/usr/bin/env bash
# Checks the presidio composite's scan.py against the fixture repository
# (synthetic, allowlisted-by-gitleaks placeholders only) and against values
# generated at run time, plus the custom recognizers' unit tests. Needs a
# virtualenv with presidio-analyzer and en_core_web_sm (PRESIDIO_PYTHON;
# created here when unset, PyPI and GitHub release access) and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCAN="${ROOT}/.github/actions/presidio/scan.py"
RECOGNIZERS="${ROOT}/policies/pii/recognizers.yml"
FIX="${HERE}/fixtures/repo"
PRESIDIO_VERSION="${PRESIDIO_VERSION:-2.2.364}"
SPACY_VERSION="${SPACY_VERSION:-3.8.16}"
MODEL_VERSION="${MODEL_VERSION:-3.8.0}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${PRESIDIO_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "presidio-analyzer==${PRESIDIO_VERSION}" "spacy==${SPACY_VERSION}" \
    "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-${MODEL_VERSION}/en_core_web_sm-${MODEL_VERSION}-py3-none-any.whl"
  PRESIDIO_PYTHON="${TMP}/env/bin/python"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <root> <files list> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  (cd "$2" && GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    "${PRESIDIO_PYTHON}" -I "${SCAN}" --root . --files-from "$3" --recognizers "${RECOGNIZERS}" \
    --sarif "${TMP}/$1.sarif" --output "${TMP}/$1.json" "${@:4}") > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
count() { jq -r --arg e "$2" '[.findings[] | select(.entity == $e)] | length' "${TMP}/$1.json"; }

echo "== recognizer unit tests"
"${PRESIDIO_PYTHON}" -I "${HERE}/test_recognizers.py" 2>&1 | tail -3 | grep -q "^OK" || fail "unit tests: $("${PRESIDIO_PYTHON}" -I "${HERE}/test_recognizers.py" 2>&1 | tail -20)"

echo "== fixture repo, defaults: cards and IBANs block, the allowlisted email and RFC 5737 address are silent, binary and vendor files skipped"
run fx "${FIX}" "${HERE}/fixtures/files.txt"
[ "${rc}" -eq 1 ] || fail "fixture rc ${rc}: $(cat "${TMP}/fx.log")"
[ "$(jq -r '.files | join(",")' "${TMP}/fx.json")" = "README.md,data/customers.csv,notebook.ipynb" ] || fail "scanned files: $(jq -c .files "${TMP}/fx.json")"
[ "$(count fx CREDIT_CARD)" = "3" ] || fail "three cards (csv x2, notebook): $(jq -c '[.findings[] | {entity, file, line}]' "${TMP}/fx.json")"
[ "$(count fx IBAN_CODE)" = "2" ] || fail "two IBANs"
[ "$(count fx US_SSN)" = "1" ] || fail "one SSN at 0.7 (the second row has no context word nearby and scores 0.5)"
[ "$(count fx EMAIL_ADDRESS)" = "0" ] || fail "allowlisted email reported"
[ "$(count fx IP_ADDRESS)" = "0" ] || fail "allowlisted RFC 5737 address reported"
[ "$(count fx PERSON)" -ge 1 ] || fail "PERSON advisory finding expected"
[ "$(jq -r '[.findings[] | select(.entity == "CREDIT_CARD" and .file == "notebook.ipynb")] | length' "${TMP}/fx.json")" = "1" ] || fail "notebook markdown cell scanned"
grep -q '^::error file=data/customers.csv,line=2,col=17,title=pii CREDIT_CARD::CREDIT_CARD (score 1.0) at data/customers.csv:2:17$' "${TMP}/fx.log" || fail "blocking annotation: $(grep '::error' "${TMP}/fx.log" | head -2)"
grep -q '^::warning file=README.md,line=3,.*title=pii PERSON::PERSON' "${TMP}/fx.log" || fail "advisory annotation"
grep -q "4242424242424242\|GB82WEST\|219-09-9999" "${TMP}/fx.log" "${TMP}/fx.summary" "${TMP}/fx.sarif" && fail "a value leaked into the log, summary or SARIF"
grep -q '^## PII scan: 3 file(s), ' "${TMP}/fx.summary" || fail "summary heading: $(head -1 "${TMP}/fx.summary")"
[ "$(jq -r '.runs[0].results | length' "${TMP}/fx.sarif")" = "$(jq -r '.findings | length' "${TMP}/fx.json")" ] || fail "sarif result count"
[ "$(jq -r '.runs[0].results[0].message.text' "${TMP}/fx.sarif")" = "CREDIT_CARD (score 1.0); value withheld" ] || fail "sarif message"
[ "$(grep '^blocking-count=' "${TMP}/fx.out" | cut -d= -f2)" = "6" ] || fail "blocking-count output: $(cat "${TMP}/fx.out")"

echo "== report-only: no block entities, exit 0"
run adv "${FIX}" "${HERE}/fixtures/files.txt" --block-entities ""
[ "${rc}" -eq 0 ] || fail "advisory rc ${rc}"
[ "$(grep -c '^::warning' "${TMP}/adv.log")" -ge 6 ] || fail "advisory annotations"

echo "== lower threshold: phone and postal code appear; the Luhn-invalid SIN does not"
run low "${FIX}" "${HERE}/fixtures/files.txt" --score-threshold 0.4 --entities CA_SIN,CA_POSTAL_CODE,PHONE_NUMBER --block-entities CA_SIN
[ "$(count low CA_SIN)" = "0" ] || fail "the Luhn-invalid SIN must be dropped: $(jq -c '[.findings[] | select(.entity == "CA_SIN")]' "${TMP}/low.json")"
run low2 "${FIX}" "${HERE}/fixtures/files.txt" --score-threshold 0.4 --entities US_SSN
[ "$(count low2 US_SSN)" = "2" ] || fail "both SSNs at 0.4"
[ "$(count low PHONE_NUMBER)" -ge 1 ] || fail "phone at 0.4"
[ "$(count low CA_POSTAL_CODE)" -ge 1 ] || fail "postal code next to a name"

echo "== generated values (never committed): a random Luhn-valid card and SSN are found"
cp -r "${FIX}" "${TMP}/gen"
"${PRESIDIO_PYTHON}" - "${TMP}/gen/data/generated.csv" <<'PY'
import random, sys
random.seed(97)
def luhn(prefix, length):
    body = prefix + "".join(str(random.randint(0, 9)) for _ in range(length - len(prefix) - 1))
    total = 0
    for i, ch in enumerate(reversed(body)):
        d = int(ch)
        if i % 2 == 0:
            d = d * 2 - 9 if d * 2 > 9 else d * 2
        total += d
    return body + str((10 - total % 10) % 10)
sin = luhn("13", 9)
open(sys.argv[1], "w").write(f"id,card,ssn\n1,{luhn('4', 16)},{random.randint(100, 899)}-{random.randint(10, 99)}-{random.randint(1000, 9999)}\n")
open(sys.argv[1].replace("generated.csv", "sin.md"), "w").write(f"Applicant SIN: {sin[:3]} {sin[3:6]} {sin[6:]}\n")
PY
printf 'data/generated.csv\ndata/sin.md\n' > "${TMP}/gen-files.txt"
run gen "${TMP}/gen" "${TMP}/gen-files.txt" --entities CREDIT_CARD,US_SSN,CA_SIN --block-entities CREDIT_CARD,US_SSN,CA_SIN
{ [ "$(count gen CREDIT_CARD)" = "1" ] && [ "$(count gen US_SSN)" = "1" ] && [ "$(count gen CA_SIN)" = "1" ]; } || fail "generated values: $(jq -c '.findings' "${TMP}/gen.json")"

echo "== unknown entity warns and is skipped; empty file list passes"
: > "${TMP}/none.txt"
run none "${FIX}" "${TMP}/none.txt" --entities CREDIT_CARD,NOT_AN_ENTITY
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}"
grep -q '^::warning title=pii::entity NOT_AN_ENTITY has no recognizer' "${TMP}/none.log" || fail "unknown entity warning"

echo "all pii-scan checks passed"
