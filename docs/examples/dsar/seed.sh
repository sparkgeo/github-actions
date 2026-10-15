#!/usr/bin/env bash
# Seed one subject (the harness sets SUBJECT_ID, SUBJECT_EMAIL, SUBJECT_NAME,
# SUBJECT_PHONE and SUBJECT_TRAIL, a JSON array of [lon, lat, iso-time]).
set -euo pipefail
: "${DATABASE_URL:?}" "${SUBJECT_ID:?}" "${SUBJECT_EMAIL:?}" "${SUBJECT_NAME:?}"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q \
  -v id="${SUBJECT_ID}" -v email="${SUBJECT_EMAIL}" -v name="${SUBJECT_NAME}" -v phone="${SUBJECT_PHONE:-}" -v trail="${SUBJECT_TRAIL:-[]}" <<'SQL'
INSERT INTO users (id, email, full_name, phone) VALUES (:'id', :'email', :'name', nullif(:'phone', ''));
INSERT INTO location_events (user_id, at, geom)
  SELECT :'id', (p->>2)::timestamptz, ST_SetSRID(ST_MakePoint((p->>0)::float, (p->>1)::float), 4326)
  FROM jsonb_array_elements(:'trail'::jsonb) AS p;
INSERT INTO audit_log (subject_id, actor, action, detail) VALUES (:'id', :'email', 'signup', jsonb_build_object('name', :'name'));
SQL
