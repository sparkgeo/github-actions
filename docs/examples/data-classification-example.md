# Data classification: STAC ingest API (worked example)

An illustrative filled-in copy of [`docs/data-classification.md`](../data-classification.md) for a service that receives client imagery uploads, builds STAC items and serves them to logged-in users. Sections 1, 2 and 5 are the template's and are not repeated here.

## 3. Storage-location inventory

| Data store | Contents | Tier | Owner | Region | Backup tier (#95) | Retention (#120) |
|---|---|---|---|---|---|---|
| `aws_s3_bucket.ingest` | raw client uploads (GeoTIFF, metadata sidecars with the uploader's email) | Confidential | geo-platform | ca-central-1 | B | 90d, lifecycle; derived products kept |
| `aws_s3_bucket.catalog` | STAC items and COGs; no personal data after sidecar stripping | Public (published) | geo-platform | ca-central-1 | C | until superseded |
| `aws_rds_cluster.app` | user accounts: name, email, organisation, hashed password, API key hashes | Confidential | geo-platform | ca-central-1 | A | 35d backups; account rows until deletion request (DSAR, #122) |
| `aws_cloudwatch_log_group.api` | request logs: method, path, status, user id (opaque), latency; emails scrubbed by middleware | Internal | geo-platform | ca-central-1 | C | 30d, `retention_in_days` |
| `aws_dynamodb_table.sessions` | session tokens, user id, expiry | Confidential | geo-platform | ca-central-1 | C | 7d, TTL |
| Stripe (SaaS) | billing contact, card on file (held by Stripe) | Restricted (cardholder data, never stored by us) | finance | vendor | n/a | vendor policy; we hold the customer id only |

## 4. Tier-to-recognizer mapping

**This repository's highest tier:** `Confidential` (the service processes personal data; cardholder data stays with the vendor and never enters the repository or its stores).

Configuration derived from the Confidential column:

```yaml
# .github/workflows/pii.yml
jobs:
  pii:
    permissions:
      contents: read
      security-events: write
      pull-requests: write
    uses: sparkgeo/github-actions/.github/workflows/pii-scan.yml@<SHA>
    with:
      entities: CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE,PHONE_NUMBER,EMAIL_ADDRESS,IP_ADDRESS,PERSON
      block-entities: CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE,PHONE_NUMBER,EMAIL_ADDRESS
      score-threshold: 0.85
```

`LOCATION` is off: the catalogue is place names end to end. `PERSON` advises at 0.85 and the changelog authors are allowlisted by path. The gitleaks PII rules run at pre-commit (`pii-rules: true`).

## 5. `.pii-allowlist.yml` (this repository)

```yaml
version: 1
literals:
  - value: ops@example.com
    reason: documentation placeholder in README and OpenAPI examples
  - value: "+1 555 0100"
    reason: reserved fictional number in the API docs
regexes:
  - pattern: '^4111 ?1111 ?1111 ?1111$'
    reason: Visa published test card (Stripe docs), used in the payment stub tests
paths:
  - glob: tests/fixtures/users/**
    reason: Faker-generated accounts (#123), seed 20260101
  - glob: CHANGELOG.md
    reason: contributor names are public GitHub handles, not customer data
```

Reviewed by a second reviewer per the review rule; `CODEOWNERS` has `/.pii-allowlist.yml @sparkgeo/security`.
