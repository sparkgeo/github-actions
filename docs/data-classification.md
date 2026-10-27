# Data classification policy (template)

SecOps plan Step 23 and Phase 0 item 8 (issue #100): a written classification is the prerequisite for every DLP control. This page is the template; a repository copies it into its own `docs/data-classification.md`, keeps the tier definitions as they are, and fills in the inventory and the repository's highest tier. The PII scanners (`gitleaks` PII rules #98, `presidio` #97, `privado` #99) take their recognizer lists and blocking thresholds from that tier, so the policy and the tooling never disagree. A filled-in copy: [`examples/data-classification-example.md`](examples/data-classification-example.md).

## 1. Tiers

| Tier | Definition | Sparkgeo examples |
|---|---|---|
| **Public** | Published or publishable without harm; no obligation to anyone. | Open geodata (OSM extracts, government open data), published STAC catalogues, this repository, documentation sites, public tile endpoints. |
| **Internal** | Sparkgeo business information; disclosure is a nuisance, not a breach. Default tier for anything not classified. | Internal designs and runbooks, non-production configuration, cost reports, meeting notes, unreleased product code with no client data. |
| **Confidential** | Client deliverables and contractual data; disclosure harms a client or Sparkgeo, or breaches a contract or privacy law. Personal data of staff, clients or end users. | Client imagery and derived products under NDA, proprietary basemaps and licensed datasets, customer names and emails in ingest pipelines, staff HR data, credentials and keys (secrets detection #4 covers these), survey responses with contact details. |
| **Restricted** | Regulated or contractually controlled data where handling rules are prescribed and a breach is reportable. | PHI (health data under PHIPA, HIPAA), CUI or ITAR-controlled geospatial data under a client contract, cardholder data (PCI DSS), government IDs (SIN, SSN, passport), precise location histories of identifiable people, biometric data. |

A dataset takes the highest tier of any field in it. A repository takes the highest tier of any data it holds or is expected to process, and records it in section 4.

## 2. Handling rules

| Rule | Public | Internal | Confidential | Restricted |
|---|---|---|---|---|
| Storage | anywhere | Sparkgeo-managed stores | named store in the inventory, encrypted at rest, access by role | named store in the inventory, encrypted at rest with a customer-managed key, access by named person, residency fixed (#120) |
| In a git repository | yes | yes | **no** real data; synthetic or anonymised fixtures only (#123); placeholders listed in `.pii-allowlist.yml` | **never**; fixtures are synthetic and reviewed |
| In logs and traces | yes | yes | no identifiers; scrub at the boundary (presidio middleware, Step 23 Advanced) | no identifiers, no free text from the record |
| In tickets, chat, documents | yes | yes | reference by identifier, not by content; attachments in the named store, not the ticket | never pasted; link to the store, access through its controls |
| In AI prompts and agent context | yes | yes, internal tools only ([agent inventory](ai-agents.md)) | only through an approved gateway with no training and no retention, listed in the inventory; never in a public model | never |
| Sharing outside Sparkgeo | free | with a reason | contract or NDA in place; least data | contract names the recipient and the control; export logged |
| Retention | n/a | as useful | per the retention table (`retention.yml`, #120; plan Step 36) | per the retention table, with deletion evidence |
| Backup tier (#95) | C | C | B | A |
| Breach | n/a | inform the security owner | incident process; client notified per contract | incident process; regulator and client notified within the statutory window |

## 3. Storage-location inventory

One row per data store the repository's software reads or writes. The tier column drives the retention (#120) and residency checks; the backup tier is the DR tier from [`dr-checklist.md`](dr-checklist.md).

| Data store | Contents | Tier | Owner | Region | Backup tier (#95) | Retention (#120) |
|---|---|---|---|---|---|---|
| `<aws_s3_bucket.ingest>` | `<raw uploads from client X>` | Confidential | `<team or user@sparkgeo.com>` | `<ca-central-1>` | B | `<90d, lifecycle>` |
| `<aws_rds_cluster.app>` | `<user accounts, email, name>` | Confidential | `<owner>` | `<ca-central-1>` | A | `<35d backups; records until account deletion>` |
| `<aws_cloudwatch_log_group.api>` | `<request logs, scrubbed>` | Internal | `<owner>` | `<ca-central-1>` | C | `<30d>` |

## 4. Tier-to-recognizer mapping

The repository declares its highest tier here and the scanners are configured from this table. `gitleaks` PII rules (#98) run at pre-commit and in the PR secrets gate; `presidio` (#97) runs on changed text and data files in CI. "Block" fails the job; "advise" annotates. The entity names are presidio's; the gitleaks rule ids carry the `PII-` prefix.

**This repository's highest tier:** `<Public | Internal | Confidential | Restricted>`

| Recognizer | Kind | Public, Internal | Confidential | Restricted |
|---|---|---|---|---|
| `CREDIT_CARD` / `PII-CREDIT_CARD` | structured | block | block | block |
| `US_SSN` / `PII-US_SSN` | structured | block | block | block |
| `CA_SIN` / `PII-CA_SIN` | structured | block | block | block |
| `IBAN_CODE` / `PII-IBAN_CODE` | structured | block | block | block |
| `PHONE_NUMBER` / `PII-E164_PHONE` | structured | advise | block | block |
| `EMAIL_ADDRESS` | structured | advise | block | block |
| `IP_ADDRESS` | structured | off | advise | block |
| `CA_POSTAL_CODE` next to a name (custom, #97) | structured | off | advise | block |
| `PERSON` | free text (NER) | off | advise, score ≥ 0.85 | block, score ≥ 0.85 |
| `LOCATION` | free text (NER) | off | off (geospatial repositories name places by design) | advise, score ≥ 0.85 |
| client-specific identifier (custom, #97) | structured | off | block | block |

Structured recognizers block at every tier because a real card number or government id has no legitimate reason to be in a repository. Free-text recognizers start advisory: `PERSON` fires on changelog authors and `LOCATION` on every place name in a geospatial repository, so they only gate at Restricted, with a raised score threshold and the allowlist below. The `pii-scan.yml` defaults (`block-entities: CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE`, `score-threshold: 0.7`) are the Public and Internal row; a Confidential or Restricted repository passes the longer `block-entities` list and the threshold from its row.

## 5. `.pii-allowlist.yml`

Every repository that runs the scanners carries `.pii-allowlist.yml` at its root listing the documented placeholders that are not PII. Starter: [`examples/.pii-allowlist.yml`](examples/.pii-allowlist.yml). Conventions:

- `literals`: exact strings (`jane.doe@example.com`, `555-0100`); `regexes`: RE2 patterns for families (`^555-01\d{2}$`, RFC 5737 ranges); `paths`: globs of files that are entirely synthetic (`tests/fixtures/**`). Each entry has a `reason`.
- Only placeholders from a reserved range belong here: `example.com`, `example.org`, `555-01xx` numbers, RFC 5737 (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and RFC 3849 (`2001:db8::/32`) addresses, the card brands' published test numbers, names from the [Faker](https://faker.readthedocs.io/) default locale. A real value is never allowlisted; it is removed and the history rewritten (secrets process, #4).
- An entry that silences a structured recognizer (`CREDIT_CARD`, `US_SSN`, `CA_SIN`, `IBAN_CODE`) names the test-number source in its `reason`.
- **Review rule**: a change to `.pii-allowlist.yml` needs a second reviewer who did not write it, and the reviewer checks the reason, not the diff. Enforce it with a `CODEOWNERS` line for the file pointing at the security owner, and a ruleset that requires code-owner review.

## 6. Adopting this policy

1. Copy this page into the repository as `docs/data-classification.md`; fill in sections 3 and 4; keep sections 1, 2 and 5 verbatim so every repository reads the same tiers.
2. Add `.pii-allowlist.yml` from the starter and the `CODEOWNERS` line.
3. Enable the gitleaks PII rules (`pii-rules: true` on `secrets-precommit.yml` and `secrets-scan.yml`, #98) and, from Confidential up, `pii-scan.yml` (#97) with the row from section 4.
4. Link the page from the repository README's security section.
