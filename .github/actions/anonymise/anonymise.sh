#!/usr/bin/env bash
# Restore a dump into a throwaway postgresql_anonymizer container with PostGIS,
# apply the masking rules, run static masking, and dump the result (issue #123).
# Env: IMAGE (digest-pinned), DUMP (plain .sql or pg_dump custom format),
# RULES (anon SECURITY LABEL file), PRECISION (geohash characters, exposed to
# the rules as the database setting anon_geo.precision), OUT (output directory), POSTGIS_PKG (apt package), DB (name).
# Writes OUT/anonymised.sql (no owners, privileges or security labels; postgis
# is the only extension kept) and OUT/masking.json (labelled columns, row
# counts). Nothing leaves the runner.
set -euo pipefail

: "${IMAGE:?}" "${DUMP:?}" "${RULES:?}" "${OUT:?}"
PRECISION="${PRECISION:-5}"
POSTGIS_PKG="${POSTGIS_PKG:-postgresql-18-postgis-3}"
DB="${DB:-fixtures}"
NAME="anon-$$"
mkdir -p "${OUT}"
cleanup() { docker rm -f "${NAME}" > /dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "${NAME}" -e POSTGRES_HOST_AUTH_METHOD=trust "${IMAGE}" > /dev/null
# The image's entrypoint runs a temporary server for initialisation (where
# anon is created) and then the real one; wait for the second, not the first.
for _ in $(seq 1 90); do docker logs "${NAME}" 2>&1 | grep -q "PostgreSQL init process complete" && break; sleep 1; done
for _ in $(seq 1 30); do docker exec "${NAME}" pg_isready -U postgres -q 2>/dev/null && break; sleep 1; done
docker exec "${NAME}" pg_isready -U postgres -q || { docker logs "${NAME}" 2>&1 | tail -20; echo "::error title=anonymise::database did not start"; exit 1; }
# The anonymizer image carries anon but not PostGIS; PGDG apt is already configured in it.
docker exec "${NAME}" bash -c "apt-get update -qq > /dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${POSTGIS_PKG} > /dev/null" \
  || { echo "::error title=anonymise::could not install ${POSTGIS_PKG}"; exit 1; }
psql() { docker exec -i "${NAME}" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql -c "CREATE DATABASE \"${DB}\""
psql -d "${DB}" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS anon;"

docker cp "${DUMP}" "${NAME}:/tmp/source.dump"
if head -c 5 "${DUMP}" | grep -q "PGDMP"; then
  docker exec "${NAME}" pg_restore -U postgres -d "${DB}" --no-owner --no-privileges /tmp/source.dump
else
  psql -d "${DB}" -f /tmp/source.dump > /dev/null
fi

docker cp "${RULES}" "${NAME}:/tmp/rules.sql"
# Static masking by the superuser needs anon.nosuperuser off for this session;
# anon.init() loads the fake-data sets the anon.fake_* functions draw from.
psql -c "ALTER DATABASE \"${DB}\" SET anon_geo.precision = '${PRECISION}'"
psql -d "${DB}" -c "SET anon.nosuperuser = off;" -c "SELECT anon.init();" -f /tmp/rules.sql -c "SELECT anon.anonymize_database();" > /dev/null
docker exec "${NAME}" psql -U postgres -d "${DB}" -At -c \
  "SELECT json_build_object('masked_columns', (SELECT json_agg(objname || ' <- ' || label ORDER BY objname) FROM pg_seclabels WHERE provider = 'anon' AND objtype = 'column'), \
                            'tables', (SELECT json_object_agg(relname, n_live_tup) FROM pg_stat_user_tables))" > "${OUT}/masking.json"
docker exec "${NAME}" pg_dump -U postgres -d "${DB}" --no-owner --no-privileges --no-security-labels --extension postgis -f /tmp/anonymised.sql
docker cp "${NAME}:/tmp/anonymised.sql" "${OUT}/anonymised.sql"
echo "anonymised dump: ${OUT}/anonymised.sql ($(wc -c < "${OUT}/anonymised.sql") bytes); $(python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('masked_columns') or []), 'masked column(s),', sum((d.get('tables') or {}).values()), 'row(s)')" "${OUT}/masking.json")"
