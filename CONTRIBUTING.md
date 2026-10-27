# Contributing

This repo is the central library of reusable GitHub Actions composite actions for the Sparkgeo organisation. All contributions must meet the security standards below before a PR can be merged.

## Workflow authoring checklist

Every PR that adds or modifies a workflow or composite action must satisfy all of the following:

```
[ ] All `uses:` references pinned to a full 40-character commit SHA with a # version comment
    e.g. uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd  # v6.0.2

[ ] `permissions:` block present at the workflow or job level — minimum: contents: read
    Default GITHUB_TOKEN permissions must never be relied upon implicitly

[ ] `actions/checkout` includes `persist-credentials: false`
    unless a subsequent step explicitly requires git credentials

[ ] No ${{ github.event.* }}, ${{ github.head_ref }}, or other user-controlled context
    variables interpolated directly inside a `run:` block — assign to an env: var first:
      env:
        HEAD_REF: ${{ github.head_ref }}
      run: echo "$HEAD_REF"

[ ] No `pull_request_target` or `workflow_run` triggers without a documented threat model
    in the workflow file header comment explaining why the trigger is safe

[ ] All `run:` steps declare `shell:` explicitly (shell: bash on Linux/macOS, shell: pwsh on Windows)

[ ] actionlint and zizmor pass locally before pushing (see Local setup below)
```

## Local setup

Install [pre-commit](https://pre-commit.com/) and the hooks for this repo:

```bash
pip install pre-commit
pre-commit install
```

The hooks run `actionlint` and `zizmor` automatically on every commit that touches workflow or action YAML files. To run them manually against all files:

```bash
pre-commit run --all-files
```

## SHA pinning

When adding or updating an action reference, always use the commit SHA of the exact version you intend to use — never a mutable tag. To find the SHA for a given tag:

```bash
gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
# e.g.
gh api repos/actions/checkout/commits/v6 --jq '.sha'
```

Dependabot keeps pinned SHAs current with automated PRs ([docs/dependabot.md](docs/dependabot.md)) — do not update SHAs manually unless fixing a security incident.

## Adding a new action

1. Create a GitHub issue (parent + context sub-issues where applicable)
2. Assign to the relevant team or individual, type: Feature, labels: `security`, `enhancement`, `documentation`, `priority: high`
3. Branch from `main`: `git checkout -b issue-<number>-<short-description>`
4. Create the composite action under `.github/actions/<name>/action.yml` — satisfy all checklist items above
5. Add a job for it in `.github/workflows/ci.yml` with minimum required permissions
6. Update the composite actions table in `README.md` with a usage example
7. Open a PR referencing the issue: `Closes #<number>`

## Migrating from the reusable workflow pattern

Prior to issue #29, this repo exposed an `Actions Quality Gate` reusable workflow
(`workflow-lint.yml`) callable via `workflow_call`. That file has been deleted.

If your repo references it:

```yaml
# OLD — no longer works
jobs:
  lint:
    uses: sparkgeo/github-actions/.github/workflows/workflow-lint.yml@<SHA>
```

Replace with direct composite action calls:

```yaml
# NEW
jobs:
  actionlint:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      checks: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/github-actionlint@<SHA>

  zizmor:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/zizmor@<SHA>
```

The composite actions are individually callable and require explicit job shells with
correct permissions (see README for full usage examples).

## Data classification and PII

Every repository that holds or processes data carries a `docs/data-classification.md` copied from [`docs/data-classification.md`](docs/data-classification.md): the four tiers (Public, Internal, Confidential, Restricted), the handling rules, the storage inventory and the repository's highest tier. That tier sets which PII recognizers block in the gitleaks PII rules (#98) and `pii-scan.yml` (#97). Placeholders that are not PII go in `.pii-allowlist.yml` (starter in [`docs/examples/.pii-allowlist.yml`](docs/examples/.pii-allowlist.yml)); a change to that file needs a second reviewer who checks the reason. Real personal data never enters a repository; fixtures are synthetic.

## Security pillars reference

| Pillar | Issue | Summary |
|---|---|---|
| Workflow authoring standards | #25 | This checklist; `actionlint`/`zizmor` gate |
| Supply chain hardening | #26 | SHA pinning policy; org allowlist; dependency locking |
| OIDC & secret federation | #27 | No static credentials; OIDC for cloud auth; environment-scoped secrets |
| Runner egress control | #28 | `harden-runner` audit → block; self-hosted runner isolation policy |
| Governance & observability | #29 | Org rulesets; audit log → SIEM; OpenSSF Scorecard |

## Findings and SLAs

Each scan gate listed below maps its findings to one row of the SLA table (from the Sparkgeo SecOps plan, Step 25). The same signal, finding type by severity by environment, always produces the same deadline, whichever tool reported it. For Critical, High, Medium and Low the clock starts when the finding is confirmed at triage. For a secret it starts when the tool first reports it.

**Track findings privately.** This repo and many consuming repos are public. A finding's tracking issue or exception request names an unfixed vulnerability, where it runs and what is holding it back, so it never goes in a public issue. Use a private repo (the org's private security tracker, or the repo itself when it is private) or a draft security advisory.

| SLA row | Definition (any one qualifies) | Production | Non-production (staging / dev) |
|---|---|---|---|
| **Secret / credential leak** | Any credential that may be live, in a repo, image, log, ticket or AI prompt | Revoke and rotate within 24 hours of detection; hard-blocked in pre-commit and CI by default | Same as production |
| **Critical** | CVSS ≥ 9.0; or a SAST/DAST finding with a confirmed exploit path; at Advanced tier also EPSS ≥ 0.10 or a CISA KEV listing (issue #80) | 48 hours | 7 days |
| **High** | CVSS 7.0–8.9; or reachable SAST/DAST finding with significant impact; or cloud/cluster misconfiguration exposing data or admin surfaces | 7 days | 30 days |
| **Medium** | CVSS 4.0–6.9; or High findings downgraded after reachability analysis | 30 days | 90 days |
| **Low** | CVSS < 4.0; informational; hardening recommendations | 90 days or next scheduled maintenance | Tracked, no SLA |

### Tiers

- **Baseline**: only the Secret and Critical rows are enforced; other findings are reported.
- **Standard**: every row is tracked with its deadline.
- **Advanced**: Standard plus the EPSS / CISA KEV uplift to Critical (`epss-override` on `dep-scan-app.yml`, issue #80).

### Workflow to SLA row

`fail-on-severity` on each workflow decides what blocks the PR (one vocabulary for every gate; issue #79). Findings below that threshold are still findings and follow the tier rules above.

| Workflow / composite | Tool | Finding class | How the SLA row is chosen |
|---|---|---|---|
| `secrets-precommit.yml` | gitleaks | Secret pattern match | Every match is the **Secret** row until proven not live. Blocks by default (`fail-on-finding: true`). |
| `secrets-scan.yml` | trufflehog | Credential | Verified match: **Secret** row, blocks. Unverified match: also the **Secret** row until someone shows it is not live; verification can fail for harmless reasons (network, no verifier, internal service). |
| `dep-scan-app.yml` (PR #54) | osv-scanner | Dependency CVE | CVSS via the shared `severity-gate`: ≥ 9.0 **Critical**, ≥ 7.0 **High**, ≥ 4.0 **Medium**, else **Low**. |
| `dependency-review` composite | dependency-review-action | New dependency CVE on a PR | GitHub advisory severity (`moderate` = **Medium**). A non-permitted licence is a merge blocker, not an SLA finding. |
| `container-scan.yml` (PR #143) | trivy image | Image CVE; secret baked into an image | trivy severity (CVSS) to the matching row; any secret is the **Secret** row. |
| `container-lint.yml` (PR #142) | hadolint | Dockerfile misconfiguration | `error` **High**, `warning` **Medium**, `info`/`style` **Low**. An unpinned base image blocks the PR regardless. |
| `iac-scan.yml` (PR #141) | checkov | IaC misconfiguration | checkov reports no severities without a cloud API key; every finding is **High**. |
| `k8s-scan.yml` (PR #150) | trivy config / fs / image | Helm/Kustomize misconfiguration; secret in a chart; image CVE | trivy severity to the matching row; any secret is the **Secret** row. |
| `k8s-policy.yml` (PR #195) | conftest | Org policy violation (registry, pinning, resources, root, privileged) | Every `deny` is **High**. It blocks the PR; an exception needs a `data-path` override or the exception process below. |
| `sast-precommit.yml` (PR #144) | semgrep | Code pattern | `ERROR` **High**, `WARNING` **Medium**, `INFO` **Low**. |
| `sast-scan.yml` (PR #145) | CodeQL | Code vulnerability | Rule `security-severity` score to the matching row; unscored rules are reported and never block. |
| `zizmor` composite | zizmor | Workflow security (injection, credential exposure, dangerous triggers) | zizmor severity: `high` **High**, `medium` **Medium**, `low`/`informational` **Low**. Reported to the Security tab; the pre-commit hook fails on findings. |
| Validation runs: `stratus-red-team.yml` (issue #178, not built yet), manual Atomic Red Team sessions, control decomposition | Stratus Red Team, Atomic Red Team | A technique recorded as *missed* by the deployed controls | Always **High**; the issue carries `validation:miss`. A High-tier trigger (unknown internet-facing asset, KEV hit on an inventoried product, release on a high-value asset) is validated within 72 hours, a Medium-tier one within 7 days: [`docs/validation.md`](docs/validation.md). |
| `lint-*.yml`, `test-*.yml`, `github-actionlint`, `kubeconform` | various | Correctness, style, coverage | Not security findings. Must pass to merge; no SLA row. |

Workflows marked with a PR number are in review and not on `main` yet. A scan gate added later (for example grype, govulncheck, GuardDog, DAST, serverless) adds its row here when it merges; until then its findings take the row that matches the tool's own severity (critical, high, medium, low).

### Decision outcomes

Every finding older than 14 days carries exactly one `outcome:*` label, on the finding's own issue, with its evidence there. The plan maps the four outcomes onto CISA SSVC decisions so a client or auditor using SSVC can read them. SSVC decisions are priorities set before remediation, so the mapping is approximate: an accepted Critical is still a Critical.

| Outcome | Label | Evidence on the issue | SSVC |
|---|---|---|---|
| **Fix** | `outcome:fix` | Merged PR and passing re-scan; for a configuration, rule, or control change, the re-validation result (prevented or detected, [`docs/validation.md` § 6](docs/validation.md#6-re-validation-gate)) | Act |
| **Mitigate** | `outcome:mitigate` | A compensating control recorded as *prevented* under emulation, or every layer of the control decomposition recorded as prevented or detected. The triager swaps the `sla:*` label one row lower; the window still runs from the issue's creation. The downgrade expires when the next run records the control, or any layer, below the outcome it was credited with | Attend |
| **Monitor** | `outcome:monitor` | The detection rule that fires for the technique, confirmed under emulation. The finding stays open and is re-reviewed each cycle | Track\* |
| **Accept** | `outcome:accept` | A link to the approved exception request ([template](docs/templates/security-exception.yml)). The approver adds the label to the finding's issue when applying `exception-approved`. Re-enters validation when the asset, the control it relied on, or the threat intelligence around it changes, not only at expiry; the [trigger table](docs/validation.md#3-trigger-table) is the signal | Track |

**AI-generated findings**: a finding raised by a model (LLM diff review, AI test sweep, pentest agent) enters the SLA table only with a reproducer, an exploited status, or a traced path from input to sink attached. Otherwise it carries `ai-informational` and starts no clock. A model's downgrade of a Critical is a recommendation until a person records the outcome.

**Forensic triage**: a KEV-listed CVE giving total control on a publicly exposed asset is `sla:critical` plus `forensic-triage`. Assume the asset was reached before the patch: scope in 0–2 hours, preserve evidence in 2–24 hours before patching, contain in 6–24 hours, analysis at 24–48 hours, escalation decision with a triage report at 48–72 hours (CISA BOD 26-04 sequence, SecOps plan Step 22). The 48-hour production deadline for the patch still applies; only the analysis and the escalation decision may run past it.

### Process

1. **Triage** the finding into a private tracking issue (see above) within one working day. Label it `security-finding` plus one `sla:*` label from [`docs/findings-labels.md`](docs/findings-labels.md). The SLA clock starts now, except for secrets (from detection).
2. **Fix** inside the window. A code fix closes the issue with its PR (`Closes #N`) plus a passing re-scan.
3. **Re-validation before close** when the fix is a configuration, rule, or control change: its PR references the issue without a closing keyword. The technique is re-run and recorded as prevented or detected, the result is linked on the issue, and then the issue is closed ([`docs/validation.md` § 6](docs/validation.md#6-re-validation-gate)).
4. **Exception** when a fix cannot land in time: file a request with the [security exception template](docs/templates/security-exception.yml) in a private repo. It gets `exception-requested`. The compensating control must have a validation run recording it as *prevented*. A member of `@sparkgeo/security-team` other than the requester checks that run and that the expiry is at most 90 days from approval, then applies `exception-approved` and adds `outcome:accept` to the finding's issue. The finding is re-reviewed at expiry, and earlier when the asset, the control, or the threat intelligence changes. A second exception for the same finding needs the accountable executive's approval as a comment on the request; the approver checks that the comment's author is the accountable executive. Secret findings are not eligible: rotate the credential.
5. **Monthly review**: findings past their deadline, findings older than 14 days without exactly one `outcome:*` label, and exceptions near or past expiry are reviewed in the monthly security meeting, using the queries in [`docs/findings-labels.md`](docs/findings-labels.md#monthly-review-queries).

## Reporting a security vulnerability

Do not open a public issue for security vulnerabilities. Use the [Security Advisory](../../security/advisories/new) process via the Security tab of this repo.
