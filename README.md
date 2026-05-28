# sparkgeo/github-actions

Reusable GitHub Actions workflows and composite actions for the Sparkgeo organisation.

All action references in this repo are pinned to full commit SHAs. See [CONTRIBUTING.md](CONTRIBUTING.md) for authoring standards and how to add new workflows.

## Reusable Workflows

Call these from any Sparkgeo repo by referencing the workflow file at a pinned SHA.

| Workflow | File | Triggers | Purpose |
|---|---|---|---|
| Workflow Lint | [`workflow-lint.yml`](.github/workflows/workflow-lint.yml) | `pull_request` on `.github/**`, `workflow_call` | Runs `actionlint` and `zizmor` against all workflow and composite action YAML files; posts annotations via GitHub Checks and uploads SARIF to the Security tab |

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
