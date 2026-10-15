#!/usr/bin/env bash
# DSAR erasure (Art. 17): delete the subject's rows; keep audit rows for the
# legal-obligation activity but strip the identifier and personal details.
# Usage: erase.sh <subject-id>
set -euo pipefail
: "${DATABASE_URL:?}"
SUBJECT="${1:?subject id}"
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -v id="${SUBJECT}" <<'SQL'
BEGIN;
UPDATE audit_log SET subject_id = NULL, actor = 'erased', detail = detail - 'name' - 'email' || jsonb_build_object('erased_at', now()) WHERE subject_id = :'id';
DELETE FROM location_events WHERE user_id = :'id';   -- explicit, even with ON DELETE CASCADE
DELETE FROM users WHERE id = :'id';
COMMIT;
SQL
