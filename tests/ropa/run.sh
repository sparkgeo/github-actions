#!/usr/bin/env bash
# Checks the ropa composite's check.py: schema validation, completeness
# against the fixture inventory (#115 shape, one PostGIS RDS cluster) and the
# fixture privado report (#99 shape, two third-party sinks), orphans,
# placeholders and the fail-on levels. Needs python3 with PyYAML and
# jsonschema (ROPA_PYTHON; a venv is created here when unset) and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${ROOT}/.github/actions/ropa/check.py"
SCHEMA="${ROOT}/policies/privacy/ropa.schema.json"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${ROPA_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "pyyaml==6.0.3" "jsonschema==4.26.0"
  ROPA_PYTHON="${TMP}/env/bin/python"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <ropa> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    "${ROPA_PYTHON}" -I "${CHECK}" --ropa "$2" --schema "${SCHEMA}" --output "${TMP}/$1.json" --comment "${TMP}/$1.md" "${@:3}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
n() { jq -r ".$2 | length" "${TMP}/$1.json"; }

echo "== example ropa.yml validates; sessions table and the CRM sink are missing rows"
run ex "${FIX}/ropa.yml" --inventory "${FIX}/inventory.json" --privado "${FIX}/privado-report.json"
[ "${rc}" -eq 1 ] || fail "example rc ${rc}: $(cat "${TMP}/ex.log")"
[ "$(n ex schema_errors)" = "0" ] || fail "schema errors: $(jq -c .schema_errors "${TMP}/ex.json")"
[ "$(n ex missing)" = "2" ] || fail "two missing rows: $(jq -c .missing "${TMP}/ex.json")"
grep -q '^::error title=ropa::store aws_dynamodb_table.sessions (data-class restricted) has no activity in ' "${TMP}/ex.log" || fail "missing store"
grep -q '^::error title=ropa::third-party sink Sinks.ThirdParties.API.api.example-crm.com (api.example-crm.com) is in the privado report but in no activity'"'"'s sinks' "${TMP}/ex.log" || fail "missing processor: $(grep crm "${TMP}/ex.log")"
[ "$(n ex orphans)" = "0" ] || fail "no orphans expected: $(jq -c .orphans "${TMP}/ex.json")"
grep -q '^## RoPA check: 2 activities, 3 sensitive store(s) in the inventory, 0 schema error(s), 2 missing, 0 orphan(s) (fail-on: missing)' "${TMP}/ex.summary" || fail "summary: $(head -1 "${TMP}/ex.summary")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| `ingest-user-locations` | consent | confidential | aws_rds_cluster.app, aws_s3_bucket.ingest | sendgrid | 90d | team-platform |' "${TMP}/ex.summary" || fail "activity row"
head -1 "${TMP}/ex.md" | grep -q '^<!-- ropa-check -->$' || fail "comment marker"
[ "$(grep '^missing-count=' "${TMP}/ex.out" | cut -d= -f2)" = "2" ] || fail "missing-count output"

echo "== fail-on none reports the same gaps as warnings and exits 0"
run none "${FIX}/ropa.yml" --inventory "${FIX}/inventory.json" --privado "${FIX}/privado-report.json" --fail-on none
[ "${rc}" -eq 0 ] || fail "none rc ${rc}"
[ "$(grep -c '^::warning title=ropa::' "${TMP}/none.log")" -ge 2 ] || fail "warnings in report-only mode"

echo "== complete record passes; a renamed store and a dropped processor are orphans; fail-on all fails"
cat > "${TMP}/complete.yml" <<'EOT'
version: 1
activities:
  - id: ingest-user-locations
    purpose: Deliver location-based alerts to users who opted in
    lawful_basis: consent
    data_subjects: [end-users]
    data_categories: [location, contact]
    classification: confidential
    stores: [aws_rds_cluster.app, aws_s3_bucket.ingest]
    sinks: [sendgrid, example-crm]
    retention: 90d
    processor_dpa: [docs/dpa/sendgrid.pdf, docs/dpa/example-crm.pdf]
    owner: team-platform
  - id: sessions
    purpose: Keep signed-in users signed in between requests
    lawful_basis: contract
    data_subjects: [end-users]
    data_categories: [credentials, device]
    classification: restricted
    stores: [aws_dynamodb_table.sessions]
    retention: 7d
    owner: team-platform
EOT
run ok "${TMP}/complete.yml" --inventory "${FIX}/inventory.json" --privado "${FIX}/privado-report.json" --fail-on all
[ "${rc}" -eq 0 ] || fail "complete rc ${rc}: $(cat "${TMP}/ok.log")"
sed -e 's/aws_s3_bucket.ingest]/aws_s3_bucket.ingest, aws_s3_bucket.ingest_v2]/' -e 's/sinks: \[sendgrid, example-crm\]/sinks: [sendgrid, example-crm, mailchimp]/' "${TMP}/complete.yml" > "${TMP}/orphans.yml"
run orph "${TMP}/orphans.yml" --inventory "${FIX}/inventory.json" --privado "${FIX}/privado-report.json"
[ "${rc}" -eq 0 ] || fail "orphans are advisory at fail-on missing: $(cat "${TMP}/orph.log")"
[ "$(n orph orphans)" = "2" ] || fail "two orphans: $(jq -c .orphans "${TMP}/orph.json")"
grep -q '^::warning title=ropa::store aws_s3_bucket.ingest_v2 is not in the inventory' "${TMP}/orph.log" || fail "orphan store"
grep -q '^::warning title=ropa::sink mailchimp matches no third-party sink' "${TMP}/orph.log" || fail "orphan sink"
run orph2 "${TMP}/orphans.yml" --inventory "${FIX}/inventory.json" --privado "${FIX}/privado-report.json" --fail-on all
[ "${rc}" -eq 1 ] || fail "orphans fail at fail-on all"

echo "== schema errors always fail: bad lawful basis, bad retention, missing lia, unknown field"
cat > "${TMP}/bad.yml" <<'EOT'
version: 1
activities:
  - id: Bad Id
    purpose: TBD
    lawful_basis: because
    data_subjects: []
    data_categories: [contact]
    classification: public
    stores: [aws_rds_cluster.app]
    retention: forever
    owner: team-platform
    extra: nope
  - id: marketing
    purpose: Send product news to people who signed up for the newsletter
    lawful_basis: legitimate_interests
    data_subjects: [subscribers]
    data_categories: [contact]
    classification: confidential
    stores: [aws_rds_cluster.app]
    retention: 24m
    owner: team-marketing
EOT
run bad "${TMP}/bad.yml" --fail-on none
[ "${rc}" -eq 1 ] || fail "schema errors must fail even at fail-on none"
for needle in "activities/0/id: 'Bad Id' does not match" "activities/0/lawful_basis: 'because' is not one of" "activities/0/classification: 'public' is not one of" "activities/0/retention: 'forever' does not match" "activities/0/data_subjects: \[\] should be non-empty" "Additional properties are not allowed ('extra' was unexpected)" "activities/1: 'lia' is a required property"; do
  grep -q "$needle" "${TMP}/bad.log" || fail "schema error missing: $needle; got: $(jq -c .schema_errors "${TMP}/bad.json")"
done
grep -q 'activity Bad Id: purpose is empty or a placeholder' "${TMP}/bad.log" || fail "placeholder purpose"

echo "== missing ropa.yml"
run nofile "${TMP}/nope.yml"
{ [ "${rc}" -eq 1 ] && grep -q 'does not exist; copy docs/examples/ropa.yml' "${TMP}/nofile.log"; } || fail "missing file"

echo "all ropa checks passed"
