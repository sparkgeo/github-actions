# Record of processing activities as code

SecOps plan Step 36 Baseline and Standard (issue #119; GDPR Art. 30, PIPEDA principle 4.8 openness). `ropa.yml` at the repository root is the record; `ropa-check.yml` validates it against [`policies/privacy/ropa.schema.json`](../policies/privacy/ropa.schema.json) and checks it for completeness against what the other scanners found: every confidential or restricted store in the asset inventory (#115) has an activity, and every third-party sink in the privado data-flow report (#99) has a processor row. Declared once, checked everywhere: the inventory and the flow map are checked against the record, not the other way round. Start from [`examples/ropa.yml`](examples/ropa.yml).

## Fields

| Field | Required | How to fill it | Art. 30 | Plan column |
|---|---|---|---|---|
| `id` | yes | Stable slug (`ingest-user-locations`); referenced by `retention.yml` (#120) and the DSAR harness (#122). | | |
| `purpose` | yes | One sentence a data subject would understand. A placeholder (`TBD`, `?`) fails the check. | 30(1)(b) purposes | purpose |
| `lawful_basis` | yes | `consent`, `contract`, `legal_obligation`, `vital_interests`, `public_task` or `legitimate_interests`; the last needs `lia`, a path to the assessment. | (Art. 6) | lawful basis |
| `data_subjects` | yes | Who the data is about: `end-users`, `client-staff`, `employees`, `survey-respondents`. | 30(1)(c) categories of data subjects | |
| `data_categories` | yes | From the enum: `identity`, `contact`, `location`, `financial`, `credentials`, `device`, `usage`, `content`, `employment`, `health`, `government_id`, `biometric`, `other`. | 30(1)(c) categories of personal data | |
| `special_categories` | no | `true` for Art. 9 data (health, biometric, ...); expect `classification: restricted` and a `dpia`. | 30(1)(c) | |
| `classification` | yes | `internal`, `confidential` or `restricted` from [`data-classification.md`](data-classification.md); personal data is never Public. A `confidential` store under an `internal` activity is flagged. | | classification |
| `stores` | yes | Inventory resource ids exactly as `inventory.json` lists them (`aws_rds_cluster.app`); the check reports a sensitive store with no activity and a store the inventory no longer has. | 30(1)(g) security measures by reference | storage location |
| `sinks` | no | Third-party processors by short name (`sendgrid`, `stripe`); matched case-insensitively against the privado sink id and destination host, so `sendgrid` covers `api.sendgrid.com`. A sink in the report with no row is a missing processor; a row with no sink is an orphan. | 30(1)(d) recipients | processor |
| `retention` | yes | `90d`, `18m`, `7y` or `until-<event>` (`until-account-deletion`); must equal the entry in `retention.yml` (#120). | 30(1)(f) erasure time limits | retention |
| `subject_keys` | for DSAR | Tables and columns that reference the data subject (`users.id`, `location_events.user_id`, `audit_log.subject_id`) with the expected erasure outcome per table (`delete`, or `anonymise` for audit rows that must stay). The DSAR harness (#122) asserts the export covers them and erasure clears them. | 30(1)(c) | |
| `processor_dpa` | with sinks | Paths or links to the DPA per processor; absent with sinks is a note. | 28(3) | |
| `transfer_mechanism` | no | `none`, `adequacy`, `sccs`, `bcrs`, `consent` for a processor outside the subjects' jurisdiction. | 30(1)(e) transfers | |
| `owner` | yes | Team or person accountable; matches the inventory `owner` tag. | 30(1)(a) controller / representative | |
| `dpia` | no | Path to the DPIA when one was needed (special categories, large-scale monitoring, new technology). | (Art. 35) | |

## Checks and levels

| Finding | `none` (Baseline) | `missing` (Standard, default) | `all` |
|---|---|---|---|
| schema error (unknown field, bad enum, bad retention, missing required field) | fail | fail | fail |
| sensitive store without an activity; third-party sink without a processor row; placeholder purpose or lawful basis; `legitimate_interests` without `lia` | warn | fail | fail |
| store not in the inventory; sink not in the report | warn | warn | fail |
| sinks without `processor_dpa`; `internal` activity on a sensitive store | note | note | note |

Without an inventory or a report the corresponding check is skipped with a notice, never passed silently.

## Where the inputs come from

- Inventory: `inventory-path` (a committed `inventory.json`) or, when empty, the `asset-inventory-latest` release that `asset-inventory.yml` publishes on the default branch (#115).
- privado report: `privado-report-path` (committed `report.json` or `privado.json`) or, when empty, the newest `privado-report` artefact from a `pii-dataflow.yml` run on the default branch (#99); needs `actions: read`.

## Consuming

```yaml
jobs:
  ropa:
    permissions:
      contents: read
      actions: read          # privado-report artefact
      pull-requests: write   # the comment
    uses: sparkgeo/github-actions/.github/workflows/ropa-check.yml@<SHA>
    with:
      actions-ref: <SHA>     # same SHA as above
      # fail-on: none        # Baseline tier while the record is being written
```

The evidence for an audit is the merged `ropa.yml` plus the green check: the record names every sensitive store and every processor the code reaches, by construction.
