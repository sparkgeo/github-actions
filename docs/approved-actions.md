# Approved Third-Party GitHub Actions

This document is the authoritative list of approved external actions for use across the Sparkgeo GitHub organisation. Any action not on this list requires a security review before use (see [Adding a new action](#adding-a-new-action)).

## Org-level allowlist policy

The GitHub organisation is configured to allow only:

- Actions created by GitHub (`github_owned_allowed: true`)
- Actions on the approved list below (`allowed_actions: selected`)
- Verified Marketplace creators are **not** automatically allowed (`verified_allowed: false`)

This is enforced at: **Org Settings → Actions → General → Allow selected actions**.

## Approved actions

| Action | Publisher | Current pinned version | Used in | Purpose | Review date |
|---|---|---|---|---|---|
| `actions/checkout` | GitHub (org-owned) | `de0fac2e` (v6.0.2) | all composite actions | Checkout repo contents | 2026-05-21 |
| `actions/upload-artifact` | GitHub (org-owned) | `043fb46d` (v7.0.1) | `scorecard` | Upload SARIF as retained artifact | 2026-05-21 |
| `actions/dependency-review-action` | GitHub (org-owned) | `a1d282b3` (v5.0.0) | `dependency-review` | Block PRs with vulnerable/denied-license deps | 2026-05-21 |
| `github/codeql-action/upload-sarif` | GitHub (org-owned) | `9e0d7b8d` (v4.35.5) | `scorecard`, `zizmor` | Upload SARIF to GitHub Security tab | 2026-05-21 |
| `ossf/scorecard-action` | OpenSSF | `4eaacf05` (v2.4.3) | `scorecard` | OpenSSF Scorecard supply-chain checks | 2026-05-21 |
| `reviewdog/action-actionlint` | reviewdog | `6fb7acc9` (v1.72.0) | `github-actionlint` | Actionlint via reviewdog; posts Check annotations | 2026-05-21 |
| `zizmorcore/zizmor-action` | zizmorcore | `5f14fd08` (v0.5.6) | `zizmor` | Zizmor static security analysis; uploads SARIF | 2026-05-21 |
| `opentofu/setup-opentofu` | OpenTofu | `847eaa4a` (v2.0.1) | `terramate-opentofu-setup` | Install OpenTofu CLI | 2026-05-21 |
| `terramate-io/terramate-action` | Terramate | `c5a13758` (v3.0.0) | `terramate-opentofu-setup` | Install Terramate CLI | 2026-05-21 |
| `step-security/harden-runner` | StepSecurity | `9af89fc7` (v2.19.4) | `ci.yml` (all jobs) | Runner egress monitor — audits outbound network calls; baseline for enforce mode | 2026-06-01 |
| `aws-actions/configure-aws-credentials` | AWS (Amazon) | `99214aa6` (v6.1.3) | `aws-oidc-auth` | Assume IAM role via GitHub OIDC; exchanges OIDC token for short-lived AWS credentials | 2026-06-09 |
| `google-github-actions/run-gemini-cli` | Google | `f77273f4` (v0) | `gemini-*.yml` workflows | Runs Gemini CLI for AI-assisted triage, review, and invocation | 2026-06-09 |
| `oxsecurity/megalinter` | OX Security | `0e3ce9b9` (v9.5.0) | `lint-app.yml` | All-language lint/format gate; auto-detects languages, emits SARIF | 2026-06-10 |

## Data handling and third-party telemetry

### step-security/harden-runner

`harden-runner` sends network egress telemetry to StepSecurity's platform (app.stepsecurity.io). This is the mechanism that powers the dashboard — it is not a side effect.

**Data sent to StepSecurity:**
- Repository name and organisation
- Workflow run ID, job name, step name
- Outbound connection metadata: destination hostname/IP, port, process name, timestamp

**Data NOT sent:** secrets, environment variables, source code, file contents.

**Implications by repo visibility:**

| Repo type | Risk | Recommendation |
|---|---|---|
| Public | Low — repo name/structure already public | Acceptable; use `egress-policy: audit` to build endpoint allowlist |
| Private | Medium — org name + CI topology exposed to StepSecurity | Review [StepSecurity privacy policy](https://www.stepsecurity.io/privacy) and data processing terms before adopting; if org policy prohibits third-party CI telemetry, omit this action |

There is no mode that suppresses telemetry while keeping the dashboard — if data leaving GitHub is unacceptable, remove `harden-runner` entirely and enforce egress via network-level controls instead.

### Decision: private repo usage

For private repos, the recommendation is to **omit `harden-runner` entirely** from consuming workflows. There is no configuration option that suppresses telemetry while keeping monitoring — the two are inseparable.

Alternatives for private repos that need egress control:

- **GitHub Enterprise Cloud (GHEC) Actions network configurations** — network-layer egress control; data stays within GitHub/Azure infrastructure; requires a GHEC subscription (approximately $21/user/month).
- **Self-hosted runners with firewall rules** — egress data stays in your own infrastructure; trades StepSecurity dependency for additional ops overhead managing the runner fleet.
- **StepSecurity Enterprise (self-hosted backend)** — licensed product where the runner agent connects to your own server rather than app.stepsecurity.io; eliminates third-party data sharing but requires procuring and operating the backend.

For static pre-run security analysis on private repos, **zizmor + actionlint** (already included in this repo) provide workflow security coverage without any outbound egress, and should be considered sufficient for the static analysis layer.

## Pinned binary tooling (non-action dependencies)

These are not GitHub Actions (no `uses:` reference) so the org allowlist does not apply, but they execute in CI and are tracked here for the same supply-chain reasons.

| Tool | Used in | Pinned version | How it is installed | Review date |
|---|---|---|---|---|
| `gitleaks` | `gitleaks` composite action, `secrets-precommit.yml`, `.pre-commit-config.yaml` | `v8.30.1` (`83d9cd68`) | Binary downloaded from the GitHub release and **verified against the published SHA-256 checksum** before use. The `gitleaks/gitleaks-action` Action is deliberately avoided — it requires a paid `GITLEAKS_LICENSE` for organisation accounts. | 2026-06-10 |
| `trufflehog` | `trufflehog` composite action, `secrets-scan.yml` | `v3.95.5` | Binary downloaded from the GitHub release and **verified against the published SHA-256 checksum** before use. The `trufflesecurity/trufflehog` Action is avoided to keep the supply chain to a single checksum-verified download; findings are converted to SARIF in-action with `jq`. | 2026-06-10 |
| `pre-commit` | `pre-commit` composite action, `lint-precommit.yml` | `4.6.0` | Run via `pipx run --spec pre-commit==4.6.0` (pipx is preinstalled on GitHub runners) — pinned version, ephemeral env, no PATH write. Hook versions themselves are pinned (to commit SHAs) in each consuming repo's `.pre-commit-config.yaml`. | 2026-06-10 |
| `tflint` | `tflint` composite action, `lint-iac.yml` | `v0.63.1` | Binary downloaded from the GitHub release and **verified against the published SHA-256 checksum** before use. The `terraform-linters/setup-tflint` Action is avoided to keep the supply chain to a single checksum-verified download. Plugin rule sets are pinned in each consuming repo's `.tflint.hcl`. | 2026-06-23 |
| `kubeconform` | `kubeconform` composite action, `lint-helm.yml` | `v0.8.0` | Binary downloaded from the GitHub release and **verified against the published SHA-256 checksum** before use. helm and kustomize are preinstalled on GitHub-hosted runners. | 2026-06-23 |

When bumping a version, update it in all locations listed above and re-confirm the checksum download path.

## Security review criteria

Before approving a new action, verify all of the following:

```
[ ] Publisher is the canonical owner of the project (not a fork or impersonator)
[ ] Action is actively maintained — last commit within 12 months, issues responded to
[ ] Source code is publicly auditable — action.yml does not pull opaque binaries without checksum
[ ] Minimum required permissions — does not request write access it does not need
[ ] No outbound network calls to non-registry endpoints (check action source for curl/wget)
[ ] Pin to a commit SHA, not a mutable tag — confirm SHA matches the intended tag
[ ] Add SHA and version to this table; add publisher pattern to org allowlist if new publisher
```

## Adding a new action

1. Open a PR adding the action to a composite action or workflow.
2. Complete the security review checklist above.
3. Add a row to the table above with the pinned SHA, version, and review date.
4. If the publisher is new, add the publisher pattern to the org allowlist via:
   ```bash
   # Append to selected_actions_allowed in org Actions permissions
   gh api --method PUT orgs/sparkgeo/actions/permissions/selected-actions \
     --input - <<'EOF'
   {
     "github_owned_allowed": true,
     "verified_allowed": false,
     "patterns_allowed": [
       "ossf/*", "reviewdog/*", "zizmorcore/*", "opentofu/*", "terramate-io/*", "step-security/*", "aws-actions/*", "google-github-actions/*", "pnpm/*",
       "<new-publisher>/*"
     ]
   }
   EOF
   ```
5. CODEOWNERS enforces that `.github/` changes require `@sparkgeo/security-team` review.

## Renovate SHA update policy

Renovate (issue #8) is configured with `pinDigests: true` for the `github-actions` manager. When a new version of an approved action is released, Renovate opens a PR that updates both the SHA and the inline version comment. Do not update SHAs manually — let Renovate handle it. The only exception is an emergency security patch: update immediately, then update this table's review date.

## Org allowlist patterns (current)

```
ossf/*
reviewdog/*
zizmorcore/*
opentofu/*
terramate-io/*
step-security/*
aws-actions/*
google-github-actions/*
pnpm/*
oxsecurity/*
```

GitHub-owned actions (`actions/*`, `github/*`) are covered by `github_owned_allowed: true` and do not need explicit patterns.
