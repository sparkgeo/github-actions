# sparkgeo/github-actions

Reusable GitHub Actions composite actions and CI workflow for the Sparkgeo organisation.

All action references in this repo are pinned to full commit SHAs. See [CONTRIBUTING.md](CONTRIBUTING.md) for authoring standards and how to add new actions.

## Workflow

| Workflow | File | Triggers | Purpose |
|---|---|---|---|
| CI | [`ci.yml`](.github/workflows/ci.yml) | `push` to `main`, `pull_request`, `schedule` (weekly), `workflow_dispatch` | Dogfoods all composite actions in this repo; serves as a live reference implementation |

## Composite Actions

Drop these into any job with a `uses:` step. Pin to a full commit SHA for supply-chain safety.

```bash
# Find the SHA to pin to
gh api repos/sparkgeo/github-actions/commits/main --jq '.sha'
```

| Action | Path | Purpose | Inputs |
|---|---|---|---|
| GitHub Actionlint | [`github-actionlint`](.github/actions/github-actionlint/action.yml) | Lints workflow and action YAML files using actionlint via reviewdog; posts annotations as GitHub Checks | None |
| Zizmor | [`zizmor`](.github/actions/zizmor/action.yml) | Runs zizmor static security analysis against workflow and action YAML files; uploads findings as SARIF to the Security tab | None |
| OpenSSF Scorecard | [`scorecard`](.github/actions/scorecard/action.yml) | Runs OpenSSF Scorecard checks; uploads SARIF to the Security tab | `publish_results` (default: `false` — always fails with HTTP 400 if set to `true`; see action description) |
| Dependency Review | [`dependency-review`](.github/actions/dependency-review/action.yml) | Blocks PRs introducing dependencies with known vulnerabilities or denied licenses; posts a summary comment | `fail-on-severity` (default: `high`), `deny-licenses` (default: `GPL-2.0,GPL-3.0,AGPL-3.0`), `comment-summary-in-pr` (default: `on-failure`) |
| Storage Optimizer | [`storage-optimizer`](.github/actions/storage-optimizer/action.yml) | Frees disk space on GitHub-hosted runners by removing unused toolchains (JDK, .NET, Swift, Android SDK, etc.) and pruning Docker | None |
| Terramate + OpenTofu Setup | [`terramate-opentofu-setup`](.github/actions/terramate-opentofu-setup/action.yml) | Installs Terramate and OpenTofu, validates generated files are up to date, initialises changed stacks, and lists changed stacks | `opentofu_version` (default: `1.10.0`), `terramate_version` (default: `0.14.7`) |

### GitHub Actionlint

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      checks: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/github-actionlint@<SHA>
```

### Zizmor

```yaml
jobs:
  security-scan:
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

### OpenSSF Scorecard

SARIF is always uploaded to the GitHub Security tab. Does not require `id-token: write` — `publish_results` defaults to `false` and no OIDC token is consumed.

> **Note on `publish_results`:** Setting `publish_results: true` always fails with HTTP 400. The scorecard webapp verifies that the calling workflow directly invokes `ossf/scorecard-action` as a job step — composite action wrapping hides that call. Keep the default (`false`). To publish to the public OpenSSF database, call `ossf/scorecard-action` directly in your workflow.

```yaml
jobs:
  scorecard:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: read
      security-events: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/scorecard@<SHA>
        # publish_results defaults to false — do not set to true (always fails with HTTP 400)
```

### Dependency Review

Only meaningful on `pull_request` events — requires PR base/head context.

```yaml
jobs:
  dependency-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/dependency-review@<SHA>
        with:
          fail-on-severity: high           # critical | high | moderate | low
          deny-licenses: GPL-2.0,AGPL-3.0  # SPDX identifiers
          comment-summary-in-pr: always    # always | on-failure | never
```

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
| Supply chain hardening | #26 | Org allowlist; dependency locking; [approved actions](docs/approved-actions.md) |
| OIDC & secret federation | #27 | No static credentials; OIDC for cloud auth; environment-scoped secrets |
| Runner egress control | #28 | `harden-runner` audit → block; self-hosted runner isolation policy |
| Enterprise governance & observability | #29 | Org rulesets; OpenSSF Scorecard; audit log → SIEM |

To report a security vulnerability, use the [Security Advisory](../../security/advisories/new) process — do not open a public issue.
