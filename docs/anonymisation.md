# Anonymised fixtures

SecOps plan Step 36 Standard (issue #123): "anonymised or synthetic data for dev and test", so no production personal data reaches a lower environment. `anonymise-fixtures.yml` masks a production dump in place with [postgresql_anonymizer](https://postgresql-anonymizer.readthedocs.io/) and lets it out only after presidio (#97) confirms the dump holds no structured personal data. It suits the PostGIS-first stack: the masking is declarative SQL, and geometry columns get a geohash truncation so location trails cannot be re-identified.

## Flow

1. The caller produces a dump in a trusted environment (`pg_dump` plain SQL or custom format) and uploads it as an artefact.
2. The workflow runs in a protected environment (required reviewers, #35): restores the dump into a throwaway container from the digest-pinned anonymizer image (PostgreSQL 18, anon 3.2) with PostGIS installed from PGDG, applies the rules file, runs `anon.anonymize_database()` (static masking), and dumps without owners, privileges, security labels or the anon extension.
3. presidio scans the dump with `CREDIT_CARD`, `US_SSN`, `CA_SIN`, `IBAN_CODE`, `EMAIL_ADDRESS` and `PHONE_NUMBER` blocking (the fake-value placeholders are allowlisted by [`examples/anon-allowlist.yml`](examples/anon-allowlist.yml)); only a clean dump is published as `fixtures-anonymised`.

The source dump never leaves the job; the anonymised artefact is the only output.

## Writing rules

Start from [`examples/anon-rules.sql`](examples/anon-rules.sql). One `SECURITY LABEL FOR anon ON COLUMN table.column IS 'MASKED WITH ...'` per personal-data column; every column the RoPA (#119) lists under `data_categories` identity, contact, location, financial, credentials, government_id, health or biometric needs one. Rules of thumb:

| Column kind | Rule | Why |
|---|---|---|
| names | `anon.fake_first_name()`, `anon.fake_last_name()` | realistic for UI testing, unlinkable |
| email | `anon.fake_email()` | reserved `example.*` domains |
| phone | `anon.random_phone_with_format('+1 604 555 01##')` | the reserved fictional range, so the gitleaks and presidio rules stay quiet |
| free text (notes, comments, addresses) | `anon.lorem_ipsum( words := N )` | replace, never redact in place: a redacted note keeps its length and shape |
| government ids, card numbers, credentials | `MASKED WITH VALUE NULL` | there is no safe realistic fake |
| dates of birth | `anon.random_date_between('1950-01-01', '2005-12-31')` or year only | age bands keep analytics usable |
| numeric amounts | `anon.noise(amount, 0.2)` or `anon.random_int_between` | keeps distributions roughly |
| foreign keys, ids | leave as is | referential integrity; ids are not personal data on their own |
| geometry (points) | `public.anon_geo_truncate(geom)` | snaps to the geohash cell centre at `anon_geo.precision` |

Custom masking functions must live in a schema anon trusts: define them in `public` and label them `SECURITY LABEL FOR anon ON FUNCTION ... IS 'TRUSTED'`, as the example does for `anon_geo_truncate`. Keep the rules file in the repository next to the schema (`db/anon-rules.sql`) and review it with the privacy owner.

## Geohash precision

`geohash-precision` sets the cell size every point is snapped to. All readings inside a cell become the same point, so a trail becomes a set of cell centres with no order inside a cell.

| Precision | Cell (lat × lon at the equator) | Use |
|---|---|---|
| 3 | 156 km × 156 km | national-level analytics, nothing finer |
| 4 | 39 km × 20 km | regional dashboards |
| 5 | 4.9 km × 4.9 km | the default: city-district level, home and work still merge |
| 6 | 1.2 km × 0.6 km | neighbourhood; only with low-frequency data (one point per user per day) |
| 7 | 153 m × 153 m | street level: re-identifiable for anyone with a second dataset; not for fixtures |

Trails are the risk, not single points: four cell-level points at typical times re-identify most people. Keep location histories at 5 or coarser, drop timestamps to the hour or day in the same rules file, and never keep home and work for the same subject below 5.

## When ARX is the better tool

postgresql_anonymizer masks each value independently; it cannot promise k-anonymity, so a rare combination (one person over 90 in a small postal code) can still single someone out in a tabular export. For a dataset that leaves the database as a table (a CSV for a partner, an analytical extract) use [ARX](https://arx.deidentifier.org/) (Apache-2.0): define quasi-identifiers, choose k, apply generalisation hierarchies, and export; then run the same presidio scan on the export. Use the anonymizer for fixtures that must keep the schema and the row structure; use ARX for releases of statistics.

## Re-identification spot check

Documented for the sample schema in [`tests/anonymise/fixtures/schema.sql`](../tests/anonymise/fixtures/schema.sql) (two users, one with a three-point morning trail across Vancouver; the test `tests/anonymise/run.sh` runs it in CI):

1. Direct identifiers: no seed value (names, email, phone, SIN, note text, coordinates) appears in the dump; the test greps for each.
2. Shapes: emails end in a reserved example domain, phones are in the 555-01xx range, the SIN column is null, notes are twelve words of lorem ipsum.
3. Trail: the three readings at precision 5 collapse onto one cell centre; the home point sits on a cell centre as well. Linking the subject's home to the trail is no longer possible from the dump.
4. Independent check: presidio over the dump reports nothing; over the raw schema it reports the emails (the control that the scan can see what it is meant to see).

Repeat the same four steps on a real dump before the first publish, and after any schema change that adds a column.

## Consuming

```yaml
jobs:
  anonymise:
    permissions:
      contents: read
      actions: read
    uses: sparkgeo/github-actions/.github/workflows/anonymise-fixtures.yml@<SHA>
    with:
      actions-ref: <SHA>                 # same SHA as above
      source-dump-artifact: prod-dump    # uploaded by a job that ran in the trusted environment
      masking-rules: db/anon-rules.sql
      geohash-precision: 5
      environment: anonymise             # required reviewers configured on it (#35)
```

The anonymizer image is `registry.gitlab.com/dalibo/postgresql_anonymizer` pinned by digest (PostgreSQL 18); a dump from an older major restores fine. Static masking by the superuser needs `anon.nosuperuser` off for the session, which the composite sets.
