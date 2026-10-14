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

Once configured, Renovate (issue #8) will keep pinned SHAs current automatically via automated PRs — do not update SHAs manually unless fixing a security incident.

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

## Security pillars reference

| Pillar | Issue | Summary |
|---|---|---|
| Workflow authoring standards | #25 | This checklist; `actionlint`/`zizmor` gate |
| Supply chain hardening | #26 | SHA pinning policy; org allowlist; dependency locking |
| OIDC & secret federation | #27 | No static credentials; OIDC for cloud auth; environment-scoped secrets |
| Runner egress control | #28 | `harden-runner` audit → block; self-hosted runner isolation policy |
| Governance & observability | #29 | Org rulesets; audit log → SIEM; OpenSSF Scorecard |

## Findings and SLAs

Every scanning workflow in this repo produces findings that map to one row of the Remediation SLA Table (SecOps plan Step 25). The same signal, finding type by severity by environment, always produces the same deadline, whichever tool reported it. The clock starts when the finding is confirmed at triage, not when the tool first fired.

| SLA row | Definition (any one qualifies) | Production | Non-production (staging / dev) |
|---|---|---|---|
| **Secret / credential leak** | Any live credential in a repo, image, log, ticket or AI prompt | Revoke and rotate within 24 hours; hard-blocked in pre-commit and CI at every tier | Same as production |
| **Critical** | CVSS ≥ 9.0; or EPSS ≥ 0.10; or on CISA KEV; or SAST/DAST finding with a confirmed exploit path | 48 hours | 7 days |
| **High** | CVSS 7.0–8.9; or reachable SAST/DAST finding with significant impact; or cloud/cluster misconfiguration exposing data or admin surfaces | 7 days | 30 days |
| **Medium** | CVSS 4.0–6.9; or High findings downgraded after reachability analysis | 30 days | 90 days |
| **Low** | CVSS < 4.0; informational; hardening recommendations | 90 days or next scheduled maintenance | Tracked, no SLA |

### Workflow to SLA row

`fail-on-severity` on each workflow decides what blocks the PR (vocabulary in `docs/gate-policy.md`, issue #79). Findings below that threshold are still findings: at Standard tier they go to the backlog with the SLA below; at Baseline only the Secret and Critical rows are enforced.

| Workflow / composite | Tool | Finding class | How the SLA row is chosen |
|---|---|---|---|
| `secrets-precommit.yml` | gitleaks | Secret pattern match | Every match is the **Secret** row until proven not live. Always blocks. |
| `secrets-scan.yml` | trufflehog | Verified credential | Verified match: **Secret** row. Unverified match: warning; investigate within the **Medium** window and re-class as Secret if it proves live. |
| `dep-scan-app.yml` | osv-scanner | Dependency CVE | CVSS via the shared `severity-gate`: ≥ 9.0 **Critical**, ≥ 7.0 **High**, ≥ 4.0 **Medium**, else **Low**. |
| `dependency-review` composite | dependency-review-action | New dependency CVE on a PR | GitHub advisory severity (`moderate` = **Medium**). A non-permitted licence is a merge blocker, not an SLA finding. |
| `container-scan.yml` | trivy image | Image CVE; secret baked into an image | trivy severity (CVSS) to the matching row; any secret is the **Secret** row. |
| `container-lint.yml` | hadolint | Dockerfile misconfiguration | `error` **High**, `warning` **Medium**, `info`/`style` **Low**. An unpinned base image blocks the PR regardless. |
| `iac-scan.yml` | checkov | IaC misconfiguration | checkov reports no severities without a cloud API key; every finding is **High**. |
| `k8s-scan.yml` | trivy config / fs / image | Helm/Kustomize misconfiguration; secret in a chart; image CVE | trivy severity to the matching row; any secret is the **Secret** row. |
| `k8s-policy.yml` | conftest | Org policy violation (registry, pinning, resources, root, privileged) | Every `deny` is **High**. It blocks the PR; an exception needs a `data-path` override or the exception process below. |
| `sast-precommit.yml` | semgrep | Code pattern | `ERROR` **High**, `WARNING` **Medium**, `INFO` **Low**. |
| `sast-scan.yml` | CodeQL | Code vulnerability | Rule `security-severity` score to the matching row; unscored rules are reported and never block. |
| Validation runs: `stratus-red-team.yml` (#178), manual Atomic Red Team sessions, control decomposition | Stratus Red Team, Atomic Red Team | A technique recorded as *missed* by the deployed controls | Always **High**; the issue carries `validation:miss`. A High-tier trigger (unknown internet-facing asset, KEV hit on an inventoried product, release on a high-value asset) is validated within 72 hours, a Medium-tier one within 7 days: [`docs/validation.md`](docs/validation.md). |
| `lint-*.yml`, `test-*.yml`, `github-actionlint`, `zizmor`, `kubeconform` | various | Correctness, style, coverage | Not security findings. Must pass to merge; no SLA row. |

Advanced tier only: EPSS ≥ 0.10 or a CISA KEV listing uplifts any CVE to **Critical** (issue #80).

### Decision outcomes

Every finding older than 14 days carries exactly one `outcome:*` label with its evidence on the issue. The four outcomes map onto CISA SSVC so a client or auditor using SSVC reads them directly.

| Outcome | Label | Evidence on the issue | SSVC |
|---|---|---|---|
| **Fix** | `outcome:fix` | Merged PR and passing re-scan; for a configuration, rule, or control change, the re-validation result (prevented or detected, [`docs/validation.md` § 6](docs/validation.md#6-re-validation-gate)) | Act |
| **Mitigate** | `outcome:mitigate` | A compensating control recorded as *prevented* under emulation, or every layer of the control decomposition recorded as prevented or detected. The finding stays open one SLA row lower; the downgrade expires when the next run no longer shows *prevented* | Attend |
| **Monitor** | `outcome:monitor` | The detection rule that fires for the technique, confirmed under emulation. The finding stays open and is re-reviewed each cycle | Track\* |
| **Accept** | `outcome:accept` | The approved [security exception](.github/ISSUE_TEMPLATE/security-exception.yml). Re-enters validation when the asset, the control it relied on, or the threat intelligence around it changes, not only at expiry; the [trigger table](docs/validation.md#3-trigger-table) is the signal | Track |

**AI-generated findings**: a finding raised by a model (LLM diff review, AI test sweep, pentest agent) enters the SLA table only with a reproducer, an exploited status, or a traced path from input to sink attached. Otherwise it carries `ai-informational` and starts no clock. A model's downgrade of a Critical is a recommendation until a person records the outcome.

**Forensic triage**: a KEV-listed CVE giving total control on a publicly exposed asset is `sla:critical` plus `forensic-triage`. Assume the asset was reached before the patch: scope in 0–2 hours, preserve evidence in 2–24 hours before patching, contain in 6–24 hours, analysis at 24–48 hours, escalation decision with a triage report at 48–72 hours (CISA BOD 26-04 sequence, SecOps plan Step 22).

### Process

1. **Triage** the finding into the tracking issue within one working day. Label it `security-finding` plus one `sla:*` label from [`docs/findings-labels.md`](docs/findings-labels.md). The SLA clock starts now.
2. **Fix** inside the window. The PR that fixes it closes the issue.
3. **Re-validation before close** when the fix is a configuration, rule, or control change: the technique is re-run and recorded as prevented or detected before the issue closes ([`docs/validation.md` § 6](docs/validation.md#6-re-validation-gate)). Code fixes close on the merged PR plus a passing re-scan.
4. **Exception** when a fix cannot land in time: open a [security exception request](.github/ISSUE_TEMPLATE/security-exception.yml). Exceptions are written, time-boxed (90 days maximum), require a compensating control recorded as *prevented* under emulation, and are signed off by the SecOps lead. They are re-reviewed at expiry and re-enter validation earlier when the asset, the control, or the threat intelligence changes. No finding receives a second exception without the executive sponsor's sign-off. Secret findings are not eligible: rotate the credential.
5. **Monthly review**: open findings past their deadline, findings older than 14 days with no `outcome:*` label, and expiring exceptions are reviewed in the monthly security meeting.

## Reporting a security vulnerability

Do not open a public issue for security vulnerabilities. Use the [Security Advisory](../../security/advisories/new) process via the Security tab of this repo.
