# sparkgeo/github-actions

Reusable GitHub Actions workflows and composite actions for the Sparkgeo organisation.

All action references in this repo are pinned to full commit SHAs. See [CONTRIBUTING.md](CONTRIBUTING.md) for authoring standards and how to add new workflows.

## Reusable Workflows

Call these from any Sparkgeo repo by referencing the workflow file at a pinned SHA.

| Workflow | File | Triggers | Purpose |
|---|---|---|---|
| CI | [`ci.yml`](.github/workflows/ci.yml) | `push` to `main`, `pull_request`, `workflow_dispatch` | Dogfoods this repo's own workflows and composite actions; serves as a live reference implementation for consuming repos |
| Actions Quality Gate | [`workflow-lint.yml`](.github/workflows/workflow-lint.yml) | `pull_request` on `.github/**`, `workflow_call` | Runs `actionlint` and `zizmor` against all workflow and composite action YAML files; posts annotations via GitHub Checks and uploads SARIF to the Security tab |
| OpenSSF Scorecard | [`scorecard.yml`](.github/workflows/scorecard.yml) | `schedule` (weekly Monday 06:00 UTC), `push` to `main`, `workflow_dispatch` | Runs OpenSSF Scorecard security checks; publishes results to the OpenSSF database and uploads SARIF to the GitHub Security tab |
| Dependency Review | [`dependency-review.yml`](.github/workflows/dependency-review.yml) | `pull_request` on lockfiles, `workflow_call` | Blocks PRs that introduce dependencies with known vulnerabilities or denied licenses; posts a summary comment on the PR |

### Usage

```yaml
# .github/workflows/lint.yml  (in a consuming repo)
on:
  pull_request:
    paths:
      - '.github/workflows/**'
      - '.github/actions/**'

jobs:
  lint:
    uses: sparkgeo/github-actions/.github/workflows/workflow-lint.yml@<SHA>
    permissions:
      contents: read
      checks: write
      security-events: write
```

Replace `<SHA>` with the full commit SHA of the version you want to pin to:

```bash
gh api repos/sparkgeo/github-actions/commits/main --jq '.sha'
```

### OpenSSF Scorecard

Runs automatically on a schedule. Add to any repo that should publish a Scorecard badge:

```yaml
# .github/workflows/scorecard.yml  (in a consuming repo)
on:
  schedule:
    - cron: '0 6 * * 1'
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  scorecard:
    uses: sparkgeo/github-actions/.github/workflows/scorecard.yml@<SHA>
    permissions:
      contents: read
      actions: read
      security-events: write
      id-token: write
```

### Dependency Review

Blocks PRs that introduce vulnerable or denied-license dependencies. Callers can override defaults via `workflow_call` inputs:

```yaml
# .github/workflows/dependency-review.yml  (in a consuming repo)
on:
  pull_request:

jobs:
  dependency-review:
    uses: sparkgeo/github-actions/.github/workflows/dependency-review.yml@<SHA>
    permissions:
      contents: read
      pull-requests: write
    with:
      fail-on-severity: high          # critical | high | moderate | low
      deny-licenses: GPL-2.0,AGPL-3.0 # SPDX identifiers
      comment-summary-in-pr: always   # always | on-failure | never
```

## Composite Actions

Drop these into any job with a `uses:` step.

| Action | Path | Purpose | Inputs |
|---|---|---|---|
| Storage Optimizer | [`storage-optimizer`](.github/actions/storage-optimizer/action.yml) | Frees disk space on GitHub-hosted runners by removing unused toolchains (JDK, .NET, Swift, Android SDK, etc.) and pruning Docker | None |
| Terramate + OpenTofu Setup | [`terramate-opentofu-setup`](.github/actions/terramate-opentofu-setup/action.yml) | Installs Terramate and OpenTofu, validates that generated files are up to date, initialises changed stacks, and lists changed stacks | `opentofu_version` (default: `1.10.0`), `terramate_version` (default: `0.14.7`) |

### Storage Optimizer

Reclaims ~30 GB on `ubuntu-latest` runners — useful before large build or scan jobs.

```yaml
steps:
  - uses: sparkgeo/github-actions/.github/actions/storage-optimizer@<SHA>
```

### Terramate + OpenTofu Setup

```yaml
steps:
  - uses: sparkgeo/github-actions/.github/actions/terramate-opentofu-setup@<SHA>
    with:
      opentofu_version: "1.10.0"   # optional — matches the action default
      terramate_version: "0.14.7"  # optional — matches the action default
```

The action will fail the job if `terramate generate` produces uncommitted output, ensuring generated files are always in sync with the source of truth.

## Security

This repo is part of the Sparkgeo GitHub Actions security programme. The pillars are:

| Pillar | Issue | Summary |
|---|---|---|
| Workflow authoring standards | #25 | SHA pinning policy; `actionlint`/`zizmor` gate |
| Supply chain hardening | #26 | Org allowlist; dependency locking |
| OIDC & secret federation | #27 | No static credentials; OIDC for cloud auth; environment-scoped secrets |
| Runner egress control | #28 | `harden-runner` audit → block; self-hosted runner isolation policy |
| Enterprise governance & observability | #29 | Org rulesets; OpenSSF Scorecard; audit log → SIEM |

To report a security vulnerability, use the [Security Advisory](../../security/advisories/new) process — do not open a public issue.
