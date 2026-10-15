#!/usr/bin/env bash
# DSAR export: write everything held about one subject to $DSAR_OUT as JSON,
# one file per table (Art. 15 and 20). Usage: export.sh <subject-id>
set -euo pipefail
: "${DATABASE_URL:?}" "${DSAR_OUT:?}"
SUBJECT="${1:?subject id}"
mkdir -p "${DSAR_OUT}"
# psql interpolates :'id' in input it reads from stdin, not in -c
q() { printf '%s\n' "$1" | psql "${DATABASE_URL}" -At -q -v ON_ERROR_STOP=1 -v id="${SUBJECT}" -f -; }
q "SELECT coalesce(json_agg(to_jsonb(u) - 'id' || jsonb_build_object('id', u.id)), '[]') FROM users u WHERE id = :'id'" > "${DSAR_OUT}/users.json"
q "SELECT coalesce(json_agg(jsonb_build_object('at', at, 'lon', ST_X(geom), 'lat', ST_Y(geom)) ORDER BY at), '[]') FROM location_events WHERE user_id = :'id'" > "${DSAR_OUT}/location_events.json"
q "SELECT coalesce(json_agg(to_jsonb(a) ORDER BY at), '[]') FROM audit_log a WHERE subject_id = :'id'" > "${DSAR_OUT}/audit_log.json"
q "SELECT jsonb_build_object('subject', :'id', 'exported_at', now(), 'tables', ARRAY['users', 'location_events', 'audit_log'])" > "${DSAR_OUT}/manifest.json"
