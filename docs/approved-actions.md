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
       "ossf/*", "reviewdog/*", "zizmorcore/*", "opentofu/*", "terramate-io/*", "step-security/*",
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
```

GitHub-owned actions (`actions/*`, `github/*`) are covered by `github_owned_allowed: true` and do not need explicit patterns.
