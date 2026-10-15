# DSAR export and erasure: the test harness

SecOps plan Step 36 Standard (issue #122): "DSAR runbook with per-store export and erasure scripts tested annually". `dsar-test.yml` runs the repository's scripts monthly against a synthetic subject in a fresh database and keeps the export bundle and the assertion log for 400 days, so "tested annually" is a dated green check rather than a calendar reminder. The repository owns the scripts and the schema; this repository owns the database, the subject and the assertions.

## Contract for the consuming repository

| Piece | Where | What |
|---|---|---|
| `scripts/dsar/export.sh <subject-id>` | repository | writes everything held about the subject to `$DSAR_OUT` (JSON or CSV, one file per table); the bundle is what a data subject receives under Art. 15 and 20 |
| `scripts/dsar/erase.sh <subject-id>` | repository | deletes or anonymises every row about the subject (Art. 17); rows that must stay (audit, legal obligation) keep no identifier or personal value |
| `ropa.yml` → `subject_keys` | repository (#119) | per activity, the tables and columns that reference the subject, with `erase: delete` (rows go) or `erase: anonymise` (rows stay, identifier and personal values gone) |
| `migrate-command` | workflow input | applies the schema to the empty service database (`DATABASE_URL` is set) |
| `seed-command` | workflow input | inserts one subject from `SUBJECT_ID`, `SUBJECT_EMAIL`, `SUBJECT_NAME`, `SUBJECT_PHONE`, `SUBJECT_TRAIL` (a JSON array of `[lon, lat, iso-time]`) |

Worked example for a small PostGIS schema: [`examples/dsar/`](examples/dsar) (`schema.sql`, `seed.sh`, `export.sh`, `erase.sh`) with the `subject_keys` in [`examples/ropa.yml`](examples/ropa.yml). The test in `tests/dsar-test/run.sh` runs exactly this.

## What the harness asserts

1. `ropa.yml` declares `subject_keys` for the tested activities.
2. Seeding the subject and a bystander succeeds; every `subject_keys` table references the subject before export.
3. The export bundle is not empty and contains the subject's id, email, name, phone and every trail point; it contains none of the bystander's id, email or name.
4. After erasure, no row in a `delete` table references the subject; no row in an `anonymise` table carries the identifier; no text column of any `subject_keys` table still holds the subject's email, name or phone; the bystander's data survived; every single-column foreign key in `public` still holds (no orphan rows).

Each assertion is a line in `dsar-log.md`; the log, `subject.json` and the export bundle are the `dsar-evidence-<run id>` artefact.

## Running it monthly

```yaml
# .github/workflows/dsar.yml
name: DSAR Test
on:
  schedule:
    - cron: '0 6 1 * *'    # first of the month
  workflow_dispatch:
  pull_request:
    paths: [scripts/dsar/**, ropa.yml, db/**]
jobs:
  dsar:
    permissions:
      contents: read
      issues: write          # the failure issue; drop with open-issue: false
    uses: sparkgeo/github-actions/.github/workflows/dsar-test.yml@<SHA>
    with:
      actions-ref: <SHA>     # same SHA as above
      database: postgis
      migrate-command: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
      seed-command: scripts/dsar/seed.sh
```

A scheduled failure opens (or comments on) one issue labelled `dsar-failure` with the failed assertions and the run link; close it when the rerun is green. The 30-day statutory clock on a real request does not wait for the fix.

## The 30-day checklist (what this harness does not do)

The harness proves the scripts. A real request still follows the runbook: 1. log the request and start the 30-day clock (GDPR Art. 12; PIPEDA 30 days, extendable once); 2. verify the requester's identity against what is held, never by asking for more data than needed; 3. identify every store from the RoPA (`stores`, `sinks`); 4. run `export.sh` per database and request the same from each processor named in `sinks`; 5. review the bundle for other people's data before release; 6. for erasure, run `erase.sh`, then record the backup exclusion statement: backups are not purged; the subject's data expires from backups with the retention in `retention.yml` (#120) and is not restored to production except to recover from an incident, in which case the erasure is re-applied; 7. reply, record the dates, close.

Manual by nature: identity verification, the processor requests, the human review of the bundle, the backup exclusion statement, and the reply.
