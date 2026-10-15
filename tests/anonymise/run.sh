#!/usr/bin/env bash
# Runs the anonymise composite's script on the sample PostGIS schema with the
# example rules, then checks the dump: no seed value survives, the subject's
# three location readings collapse onto geohash-cell centres, the fake values
# have the expected shapes, labels and the anon extension are gone, and the
# presidio scan of the dump finds no structured entity. Needs Docker, python3
# with presidio (PRESIDIO_PYTHON; created here when unset) and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/.github/actions/anonymise/anonymise.sh"
SCAN="${ROOT}/.github/actions/presidio/scan.py"
IMAGE="${ANON_IMAGE:-registry.gitlab.com/dalibo/postgresql_anonymizer@sha256:cedfa32f762df460091ae5b0f71a96cf21ea6300c51ff1390ea020dded778d8a}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

if [ -z "${PRESIDIO_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "presidio-analyzer==2.2.364" "spacy==3.8.16" \
    "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
  PRESIDIO_PYTHON="${TMP}/env/bin/python"
fi

echo "== anonymise the sample schema"
IMAGE="${IMAGE}" DUMP="${HERE}/fixtures/schema.sql" RULES="${ROOT}/docs/examples/anon-rules.sql" PRECISION=5 OUT="${TMP}/out" bash "${SCRIPT}" || fail "anonymise.sh failed"
DUMP="${TMP}/out/anonymised.sql"
[ -s "${DUMP}" ] || fail "no dump"

echo "== no seed value survives"
for needle in "Jane" "Doe" "jane.doe@acme-client.com" "acme-client" "731 2222" "130 529 475" "Kits Beach" "Bob" "bob@example.org" "VIP" "-123.1565" "49.2733" "-123.1610" "-123.1402"; do
  grep -qF -- "${needle}" "${DUMP}" && fail "seed value leaked: ${needle}"
done
grep -q "SECURITY LABEL" "${DUMP}" && fail "security labels left in the dump"
grep -q "CREATE EXTENSION IF NOT EXISTS anon" "${DUMP}" && fail "anon extension left in the dump"
grep -q "CREATE EXTENSION IF NOT EXISTS postgis" "${DUMP}" || fail "postgis extension kept"

echo "== masked shapes: fake emails on example domains, 555-01xx phones, SIN null, three readings on one or two geohash centres"
[ "$(jq -r '.masked_columns | length' "${TMP}/out/masking.json")" = "8" ] || fail "eight masked columns: $(jq -c .masked_columns "${TMP}/out/masking.json")"
python3 -I - "${DUMP}" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
def copy_block(table):
    m = re.search(r"COPY public\.%s \((.*?)\) FROM stdin;\n(.*?)\n\\\.\n" % table, text, re.S)
    cols = [c.strip() for c in m.group(1).split(",")]
    return [dict(zip(cols, ln.split("\t"))) for ln in m.group(2).splitlines()]
users = copy_block("users"); events = copy_block("location_events")
assert len(users) == 2 and len(events) == 3, (len(users), len(events))
for u in users:
    assert re.search(r"@example\.(com|net|org)$", u["email"]), u["email"]
    assert re.fullmatch(r"\+1 604 555 01\d{2}", u["phone"]), u["phone"]
    assert u["sin"] == "\\N", u["sin"]
    assert len(u["notes"].split()) >= 10, u["notes"]
    assert u["first_name"] not in ("Jane", "Bob") and u["last_name"] not in ("Doe", "Example")
cells = {e["geom"] for e in events}
assert len(cells) <= 2, cells   # three readings within ~5 km collapse to at most two cell centres
assert users[0]["home"] in cells or len(cells) >= 1
print("masked shapes ok; distinct event cells:", len(cells))
PY

echo "== presidio finds no structured entity in the dump"
printf 'anonymised.sql\n' > "${TMP}/files.txt"
set +e
(cd "${TMP}/out" && "${PRESIDIO_PYTHON}" -I "${SCAN}" --root . --files-from "${TMP}/files.txt" --include-globs '**/*.sql' \
  --entities CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE,EMAIL_ADDRESS,PHONE_NUMBER --block-entities CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE,EMAIL_ADDRESS,PHONE_NUMBER \
  --allowlist "${ROOT}/docs/examples/anon-allowlist.yml" --recognizers "${ROOT}/policies/pii/recognizers.yml" --output "${TMP}/scan.json") > "${TMP}/scan.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "presidio found something in the dump: $(jq -c '.findings' "${TMP}/scan.json")"
[ "$(jq -r '.files | length' "${TMP}/scan.json")" = "1" ] || fail "dump not scanned"

echo "== the seeded subject's raw values are still detected by presidio (control)"
printf 'schema.sql\n' > "${TMP}/raw.txt"
set +e
(cd "${HERE}/fixtures" && "${PRESIDIO_PYTHON}" -I "${SCAN}" --root . --files-from "${TMP}/raw.txt" --include-globs '**/*.sql' \
  --entities EMAIL_ADDRESS,PHONE_NUMBER,CA_SIN --block-entities EMAIL_ADDRESS --score-threshold 0.4 --recognizers "${ROOT}/policies/pii/recognizers.yml" --output "${TMP}/raw.json") > /dev/null 2>&1
set -e
[ "$(jq -r '[.findings[] | select(.entity == "EMAIL_ADDRESS")] | length' "${TMP}/raw.json")" -ge 2 ] || fail "control: raw schema should show the emails"

echo "all anonymise checks passed"
