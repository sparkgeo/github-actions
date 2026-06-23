# sparkgeo/github-actions

[![CI](https://github.com/sparkgeo/github-actions/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sparkgeo/github-actions/actions/workflows/ci.yml)

Reusable GitHub Actions composite actions and CI workflow for the Sparkgeo organisation.

All action references in this repo are pinned to full commit SHAs. See [CONTRIBUTING.md](CONTRIBUTING.md) for authoring standards and how to add new actions.

## Workflow

| Workflow | File | Triggers | Purpose |
|---|---|---|---|
| CI | [`ci.yml`](.github/workflows/ci.yml) | `push` to `main`, `pull_request`, `schedule` (weekly), `workflow_dispatch` | Dogfoods all composite actions in this repo; serves as a live reference implementation |
| Secrets Pre-commit | [`secrets-precommit.yml`](.github/workflows/secrets-precommit.yml) | `workflow_call` | Reusable Gitleaks gate — call from a consuming repo's PR workflow to block secrets in CI |
| Secrets PR Scan | [`secrets-scan.yml`](.github/workflows/secrets-scan.yml) | `workflow_call` | Reusable TruffleHog gate — verifies matched credentials are live; hard-blocks on verified secrets; uploads SARIF to the Security tab |
| Lint Pre-commit | [`lint-precommit.yml`](.github/workflows/lint-precommit.yml) | `workflow_call` | Reusable gate that runs the consuming repo's `.pre-commit-config.yaml` hooks in CI; language-agnostic; shared across app/IaC/Helm lint stages |
| Lint App | [`lint-app.yml`](.github/workflows/lint-app.yml) | `workflow_call` | Reusable MegaLinter gate — auto-detects all languages, blocks on any linter error, uploads SARIF to the Security tab |
| Lint IaC | [`lint-iac.yml`](.github/workflows/lint-iac.yml) | `workflow_call` | Reusable tflint gate — recursive Terraform/OpenTofu lint, provider-agnostic via `.tflint.hcl`, inline PR annotations, plugin caching |

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
| Dependency Review | [`dependency-review`](.github/actions/dependency-review/action.yml) | Blocks PRs introducing dependencies with known vulnerabilities or non-permitted licenses; posts a summary comment. Also supports non-PR invocation via `base-ref`/`head-ref`. | `fail-on-severity` (default: `high`), `allow-licenses` (default: `MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Unlicense, CC0-1.0`), `comment-summary-in-pr` (default: `on-failure`), `base-ref` (default: `""`), `head-ref` (default: `""`) |
| Storage Optimizer | [`storage-optimizer`](.github/actions/storage-optimizer/action.yml) | Frees disk space on GitHub-hosted runners by removing unused toolchains (JDK, .NET, Swift, Android SDK, etc.) and pruning Docker | None |
| Terramate + OpenTofu Setup | [`terramate-opentofu-setup`](.github/actions/terramate-opentofu-setup/action.yml) | Installs Terramate and OpenTofu, validates generated files are up to date, initialises changed stacks, and lists changed stacks | `opentofu_version` (default: `1.10.0`), `terramate_version` (default: `0.14.7`) |
| AWS OIDC Auth | [`aws-oidc-auth`](.github/actions/aws-oidc-auth/action.yml) | Assumes an IAM role via GitHub OIDC — no static credentials stored; enforces traceable session name `{repo}-{run_id}` | `role-arn` (required), `aws-region` (required), `role-session-name` (default: `{repo}-{run_id}`) |
| Gitleaks Secret Scan | [`gitleaks`](.github/actions/gitleaks/action.yml) | Pattern-based secret detection; hard-fails on any match. Scans the PR commit range on `pull_request`, else the full git history. Installs a checksum-verified Gitleaks binary (no paid license) | `version` (default: `8.30.1`), `config-path` (default: `.gitleaks.toml`), `fail-on-finding` (default: `true`) |
| TruffleHog Verified Scan | [`trufflehog`](.github/actions/trufflehog/action.yml) | Verified active-secret detection; hard-fails on verified secrets, unverified matches are warnings. Converts findings to SARIF and uploads to the Security tab. Installs a checksum-verified TruffleHog binary | `version` (default: `3.95.5`), `only-verified` (default: `true`), `sarif-upload` (default: `true`) |
| Pre-commit | [`pre-commit`](.github/actions/pre-commit/action.yml) | Runs the consuming repo's `.pre-commit-config.yaml` hooks; changed files on PRs, all files otherwise. Language-agnostic | `version` (default: `4.6.0`), `config-path` (default: `.pre-commit-config.yaml`), `from-ref`/`to-ref` (default: PR base/head) |
| TFLint | [`tflint`](.github/actions/tflint/action.yml) | Recursive Terraform/OpenTofu lint; provider rule sets via consuming-repo `.tflint.hcl`; inline PR annotations. Installs a checksum-verified tflint binary | `version` (default: `0.63.1`), `directory` (default: `.`), `minimum-failure-severity` (default: `error`) |

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

Works on `pull_request` events (automatic base/head from PR context) and on push/non-PR events by passing `base-ref`/`head-ref` explicitly. Skip on initial branch push (`event.before` = zero SHA — no base to compare).

```yaml
jobs:
  dependency-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request' || (github.event_name == 'push' && github.ref == 'refs/heads/main' && github.event.before != '0000000000000000000000000000000000000000')
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/dependency-review@<SHA>
        with:
          fail-on-severity: high                              # critical | high | moderate | low
          allow-licenses: MIT, Apache-2.0, BSD-2-Clause      # SPDX identifiers; deps with other licenses fail
          comment-summary-in-pr: always                       # always | on-failure | never
          base-ref: ${{ github.event_name == 'push' && github.event.before || '' }}  # leave empty on pull_request
          head-ref: ${{ github.event_name == 'push' && github.sha || '' }}           # leave empty on pull_request
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

### AWS OIDC Auth

Exchanges a GitHub OIDC token for short-lived AWS credentials — no static key stored as a secret. See [docs/oidc-trust-policies.md](docs/oidc-trust-policies.md) for IAM trust policy setup and migration checklist.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write    # required for OIDC token exchange
      contents: read
    steps:
      - uses: actions/checkout@<SHA>
        with:
          persist-credentials: false
      - uses: sparkgeo/github-actions/.github/actions/aws-oidc-auth@<SHA>
        with:
          role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ca-central-1
      # AWS credentials now available in environment
      - run: aws sts get-caller-identity
```

Store the role ARN as a repository or environment **variable** (not a secret — ARNs are not sensitive). For production deployments, add a `environment: production` key to the job and configure required reviewers in Settings → Environments.

### Gitleaks Secret Scan

Two layers of secret detection — a local pre-commit hook (instant, zero CI cost) and a CI gate (catches contributors without the hook).

**Local hook** — add to the consuming repo's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: 83d9cd684c87d95d656c1458ef04895a7f1cbd8e  # v8.30.1 — pin to the SHA, not the tag
    hooks:
      - id: gitleaks
```

**CI gate** — call the reusable workflow on every PR:

```yaml
# .github/workflows/secrets.yml
name: Secrets Detection
on: [pull_request]
permissions:
  contents: read
jobs:
  gitleaks:
    uses: sparkgeo/github-actions/.github/workflows/secrets-precommit.yml@<SHA>
    with:
      actions-ref: <SHA>   # pin to the SAME SHA so the composite is immutable too
```

Or drop the composite action straight into an existing job:

```yaml
- uses: actions/checkout@<SHA>
  with:
    persist-credentials: false
    fetch-depth: 0          # full history so the PR commit range can be scanned
- uses: sparkgeo/github-actions/.github/actions/gitleaks@<SHA>
```

**Allowlisting false positives** — add a `.gitleaks.toml` to the consuming repo root. Every entry must carry a comment explaining why the finding is a false positive:

```toml
[allowlist]
  description = "Allowlisted patterns"
  paths = [
    '''tests/fixtures/''',
    '''docs/examples/''',
  ]
  regexes = [
    '''EXAMPLE_KEY_[A-Z0-9]{20}''',  # synthetic example keys in docs
  ]
```

### TruffleHog Verified Scan

The PR-stage counterpart to gitleaks. Where gitleaks flags *patterns* fast, TruffleHog confirms which matches are **live, verified credentials** before blocking — cutting false-positive noise. Findings upload to the Security tab as SARIF (verified → `error`, unverified → `warning`).

Run both gates together on every PR:

```yaml
# .github/workflows/secrets.yml
name: Secrets Detection
on: [pull_request]
permissions:
  contents: read
jobs:
  gitleaks:
    uses: sparkgeo/github-actions/.github/workflows/secrets-precommit.yml@<SHA>
    with:
      actions-ref: <SHA>

  trufflehog:
    uses: sparkgeo/github-actions/.github/workflows/secrets-scan.yml@<SHA>
    permissions:
      contents: read
      security-events: write   # required for SARIF upload
    with:
      actions-ref: <SHA>
```

**Gate behaviour:** a verified active secret hard-blocks the merge immediately. Unverified pattern matches are surfaced as warnings in the Security tab only (set `only-verified: false` to block on those too).

**When a verified secret is detected:** revoke it immediately (do not wait for the PR to close), rotate at the source, then purge it from git history with `git filter-repo` / BFG and coordinate a force-push. See [SECURITY.md](SECURITY.md).

### Lint Pre-commit

The non-bypassable CI counterpart to a developer's local pre-commit hook — runs the consuming repo's `.pre-commit-config.yaml` against the PR diff so anything that slipped past a missing local hook is still caught. Language-agnostic; all tool config lives in the consuming repo. Shared across the app, IaC, and Helm lint stages (#9 / #10 / #11).

```yaml
# .github/workflows/lint.yml
name: Lint
on: [pull_request]
permissions:
  contents: read
jobs:
  pre-commit:
    uses: sparkgeo/github-actions/.github/workflows/lint-precommit.yml@<SHA>
    with:
      actions-ref: <SHA>   # pin to the SAME SHA so the composite is immutable too
```

The consuming repo provides a `.pre-commit-config.yaml` at its root — e.g. for a Python + Node.js repo:

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: <SHA>  # v0.x.x
    hooks:
      - id: ruff
      - id: ruff-format
  - repo: https://github.com/rbubley/mirrors-prettier
    rev: <SHA>  # v3.x.x
    hooks:
      - id: prettier
```

### Lint App (MegaLinter)

The PR-stage gate for application source. [MegaLinter](https://github.com/oxsecurity/megalinter) auto-detects every language in the repo and runs the right linter/formatter check for each — no per-language config in the workflow call. Findings upload to the Security tab as SARIF; the job blocks on any linter error.

```yaml
# .github/workflows/lint.yml
name: Lint
on: [pull_request]
jobs:
  pre-commit:
    uses: sparkgeo/github-actions/.github/workflows/lint-precommit.yml@<SHA>
    with:
      actions-ref: <SHA>

  app:
    uses: sparkgeo/github-actions/.github/workflows/lint-app.yml@<SHA>
    permissions:
      contents: read
      security-events: write   # required for SARIF upload
    with:
      filter-regex-exclude: 'dist/|generated/'   # optional
```

Tune linters via an optional `.mega-linter.yml` in the consuming repo (enable/disable specific linters, set `DISABLE_ERRORS` per tool, etc.).

> **Org allowlist:** `lint-app.yml` uses `oxsecurity/megalinter`, so `oxsecurity/*` must be on the org allowlist (already added in [approved-actions](docs/approved-actions.md); apply with the `gh api` allowlist update if not yet live).

### Lint IaC (tflint)

The PR-stage gate for Terraform / OpenTofu. Runs `tflint --recursive`; cloud-provider rule sets are activated by a `.tflint.hcl` in the consuming repo, so the workflow is provider-agnostic. Findings show as inline PR annotations and the job blocks on any finding at or above `minimum-failure-severity`. Plugin downloads are cached.

```yaml
# .github/workflows/lint.yml (add to the same file)
  iac:
    uses: sparkgeo/github-actions/.github/workflows/lint-iac.yml@<SHA>
    with:
      actions-ref: <SHA>
      directory: .                      # default; point at a subdir if IaC lives there
      minimum-failure-severity: error   # default; 'warning' to be stricter
```

Add a `.tflint.hcl` to the consuming repo root to enable provider rule sets — e.g. AWS:

```hcl
plugin "aws" {
  enabled = true
  version = "0.x.x"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

Swap `aws` for `google` ([tflint-ruleset-google](https://github.com/terraform-linters/tflint-ruleset-google)) or `azurerm` ([tflint-ruleset-azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm)). The default `terraform` ruleset is always active with no `.tflint.hcl`.

For the local fast-feedback stage, copy [`examples/iac.pre-commit-config.yaml`](examples/iac.pre-commit-config.yaml) to your repo root as `.pre-commit-config.yaml` (`terraform_fmt` / `terraform_validate` / `terraform_tflint`) and gate it in CI with `lint-precommit.yml`.

#### OpenTofu & Terramate notes

- **OpenTofu:** works on Terraform-compatible `.tf` files. tflint does **not** read `.tofu` files and does not understand OpenTofu-only syntax (e.g. the state/plan `encryption` block, 1.7+). Standard `.tf` OpenTofu code lints fine; keep OpenTofu-specific config out of `.tf` if you hit false positives.
- **Terramate:** tflint ignores `.tm.hcl` stack files (only `.tf` is linted). If you **commit** terramate-generated `.tf` (`_terramate_generated_*.tf`), `tflint --recursive` lints those too — they often trip rules like `terraform_required_providers` or `terraform_unused_declarations` that you can't hand-fix. Either fix the generate templates, disable those rules in `.tflint.hcl`, or rely on the default `error` severity floor (these are `Warning`-level, so they annotate but do not block).

## Consuming repo CI setup

Public and private repos use different subsets of these actions. The key differences are `harden-runner` (sends egress telemetry to StepSecurity — omit on private repos) and `scorecard` (requires public visibility to produce meaningful scores).

### Public repo

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '0 6 * * 1'
permissions:
  contents: read
jobs:
  actionlint:
    runs-on: ubuntu-latest
    permissions: { contents: read, checks: write }
    steps:
      - uses: step-security/harden-runner@<SHA>
        with: { egress-policy: audit }
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/github-actionlint@<SHA>

  zizmor:
    runs-on: ubuntu-latest
    permissions: { contents: read, security-events: write }
    steps:
      - uses: step-security/harden-runner@<SHA>
        with: { egress-policy: audit }
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/zizmor@<SHA>

  scorecard:  # public repos only — checks degrade on private repos
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    permissions: { contents: read, actions: read, security-events: write }
    steps:
      - uses: step-security/harden-runner@<SHA>
        with: { egress-policy: audit }
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/scorecard@<SHA>

  dependency-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions: { contents: read, pull-requests: write }
    steps:
      - uses: step-security/harden-runner@<SHA>
        with: { egress-policy: audit }
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/dependency-review@<SHA>
```

### Private repo

Same structure — drop `harden-runner` from every job and drop the `scorecard` job entirely:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  actionlint:
    runs-on: ubuntu-latest
    permissions: { contents: read, checks: write }
    steps:
      # harden-runner omitted — sends egress telemetry to StepSecurity (third party)
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/github-actionlint@<SHA>

  zizmor:
    runs-on: ubuntu-latest
    permissions: { contents: read, security-events: write }
    # security-events: write requires GitHub Advanced Security on private repos
    steps:
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/zizmor@<SHA>

  # scorecard omitted — most checks require public repo visibility

  dependency-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions: { contents: read, pull-requests: write }
    steps:
      - uses: actions/checkout@<SHA>
        with: { persist-credentials: false }
      - uses: sparkgeo/github-actions/.github/actions/dependency-review@<SHA>
```

See [docs/approved-actions.md](docs/approved-actions.md) for full data handling and telemetry details.

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
