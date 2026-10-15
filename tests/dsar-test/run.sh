#!/usr/bin/env bash
# Runs the DSAR harness against a PostGIS container with the example schema
# and scripts (docs/examples/dsar) and the example ropa.yml: the happy path
# passes every assertion; a broken erase script (audit rows keep the id) and
# an export that leaks the bystander fail the right assertions. Needs Docker,
# psql on PATH, python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
HARNESS="${ROOT}/.github/actions/dsar-test/harness.py"
EX="${ROOT}/docs/examples/dsar"
IMAGE="${DSAR_IMAGE:-postgis/postgis@sha256:94146ac37bc61e2322f88016056c5920729cb8c64c8542ed590af8fc2abdac07}"
TMP="$(mktemp -d)"
NAME="dsar-$$"
PORT="${DSAR_PORT:-55432}"
cleanup() { docker rm -f "${NAME}" > /dev/null 2>&1 || true; rm -rf "${TMP:?}"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

docker run -d --name "${NAME}" -e POSTGRES_PASSWORD=dsar -p "127.0.0.1:${PORT}:5432" "${IMAGE}" > /dev/null
for _ in $(seq 1 90); do docker logs "${NAME}" 2>&1 | grep -q "PostgreSQL init process complete" && break; sleep 1; done
export DATABASE_URL="postgresql://postgres:dsar@127.0.0.1:${PORT}/postgres"
for _ in $(seq 1 30); do psql "${DATABASE_URL}" -c "select 1" > /dev/null 2>&1 && break; sleep 1; done
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -f "${EX}/schema.sql"

run() {  # <name> <erase cmd> <export cmd>; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" python3 -I "${HARNESS}" --ropa "${ROOT}/docs/examples/ropa.yml" --activities ingest-user-locations \
    --seed "${EX}/seed.sh" --export "$3" --erase "$2" --out "${TMP}/$1" --random-seed "$1" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
passed() { jq -r '.assertions - .failed' "${TMP}/$1/report.json"; }

echo "== example scripts: every assertion passes"
run ok "${EX}/erase.sh" "${EX}/export.sh"
[ "${rc}" -eq 0 ] || fail "happy path rc ${rc}: $(cat "${TMP}/ok.log")"
[ "$(jq -r .failed "${TMP}/ok/report.json")" = "0" ] || fail "failed assertions: $(jq -c '.log | map(select(startswith("- FAIL")))' "${TMP}/ok/report.json")"
[ "$(passed ok)" -ge 20 ] || fail "assertion count $(passed ok)"
grep -q '^- PASS: ingest-user-locations: audit_log.subject_id no longer references the subject (anonymise)' "${TMP}/ok/dsar-log.md" || fail "audit anonymise assertion"
grep -q '^- PASS: foreign key location_events_user_id_fkey holds' "${TMP}/ok/dsar-log.md" || fail "fk assertion"
grep -q '^- PASS: the bystander.s data survived the erasure' "${TMP}/ok/dsar-log.md" || fail "bystander survives"
[ -s "${TMP}/ok/export/location_events.json" ] && [ "$(jq length "${TMP}/ok/export/location_events.json")" = "4" ] || fail "export bundle trail"
[ "$(grep '^failed=' "${TMP}/ok.out" | cut -d= -f2)" = "0" ] || fail "failed output"
grep -q '^## DSAR test: ' "${TMP}/ok.log" || fail "summary heading"

echo "== erase that leaves the audit identifier: the anonymise assertion and the column search fail"
sed 's/UPDATE audit_log SET subject_id = NULL, actor = .erased., detail = detail - .name. - .email. || jsonb_build_object(.erased_at., now()) WHERE subject_id = :.id.;/-- audit rows left as they are/' "${EX}/erase.sh" > "${TMP}/erase-bad.sh"; chmod +x "${TMP}/erase-bad.sh"
grep -q "audit rows left" "${TMP}/erase-bad.sh" || fail "bad erase fixture not built"
run bad "${TMP}/erase-bad.sh" "${EX}/export.sh"
[ "${rc}" -eq 1 ] || fail "bad erase must fail"
grep -q '^- FAIL: ingest-user-locations: audit_log.subject_id still references the subject in 1 row(s)' "${TMP}/bad/dsar-log.md" || fail "audit failure: $(grep FAIL "${TMP}/bad/dsar-log.md")"
grep -q '^- FAIL: audit_log: 1 row(s) still hold the subject.s email' "${TMP}/bad/dsar-log.md" || fail "column search failure"

echo "== export that dumps every user: the bystander assertions fail"
printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p "$DSAR_OUT"\npsql "$DATABASE_URL" -At -c "select json_agg(u) from users u" > "$DSAR_OUT/users.json"\n' > "${TMP}/export-leaky.sh"; chmod +x "${TMP}/export-leaky.sh"
run leaky "${EX}/erase.sh" "${TMP}/export-leaky.sh"
[ "${rc}" -eq 1 ] || fail "leaky export must fail"
grep -q "^- FAIL: export does not contain the bystander's email" "${TMP}/leaky/dsar-log.md" || fail "bystander leak: $(grep FAIL "${TMP}/leaky/dsar-log.md")"

echo "== ropa.yml without subject_keys is an explicit failure"
printf 'version: 1\nactivities:\n  - id: x\n    stores: [a.b]\n' > "${TMP}/nokeys.yml"
set +e; python3 -I "${HARNESS}" --ropa "${TMP}/nokeys.yml" --seed true --export true --erase true --out "${TMP}/nokeys" > "${TMP}/nokeys.log" 2>&1; rc=$?; set -e
{ [ "${rc}" -eq 1 ] && grep -q 'declares no subject_keys' "${TMP}/nokeys.log"; } || fail "no subject_keys"

echo "all dsar-test checks passed"
