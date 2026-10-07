# Dependabot: GitHub Actions updates

Dependabot version updates and security updates are free on every GitHub plan
and need no infrastructure. In the Sparkgeo organisation Dependabot owns
exactly one ecosystem, `github-actions`, in every repository. The central
Renovate runner (#86) owns everything else and has its `github-actions`
manager disabled, so no dependency is ever bumped by both.

| Ecosystem | Tool | Why |
|---|---|---|
| `github-actions` (SHA-pinned `uses:` references) | Dependabot | Native, zero infrastructure, understands SHA pins and keeps the `# vX.Y.Z` comment current |
| npm, pip, Go modules, Cargo, Maven | Renovate | One runner, one config, grouped and scheduled across repos |
| Terraform / OpenTofu providers and modules | Renovate | `terraform` manager |
| Helm chart dependencies, `values.yaml` image tags, Kustomize images | Renovate | `helmv3`, `helm-values`, `kustomize` managers |
| Dockerfile base images (tag and digest) | Renovate | `docker` manager with `pinDigests: true` (plan Step 24); `hadolint` in #13 fails unpinned `FROM` lines before Renovate ever sees them |

## Reference `.github/dependabot.yml` for consuming repos

Copy as is. The `cooldown` lets a release settle for a week before it is
proposed; the `groups` block folds all minor and patch bumps into one weekly
PR and leaves major bumps as individual PRs so a runtime change is reviewed
on its own.

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
    groups:
      actions-minor-and-patch:
        applies-to: version-updates
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
    commit-message:
      prefix: "ci"
    labels:
      - "dependencies"
```

Do not add other `package-ecosystem` entries; Renovate covers them. A repo
that is not yet onboarded to Renovate may add them temporarily and must
remove them when it is.

## Security updates and alerts

Dependabot alerts and security updates are separate from version updates and
apply to every ecosystem in the dependency graph, including the ones Renovate
manages. They should be on for every repository.

**Organisation level (owner, UI):** Settings → Code security → Global
settings → enable "Dependency graph", "Dependabot alerts", "Dependabot
security updates", and "Automatically enable for new repositories".

**Repository level (admin, API):**

```bash
gh api -X PUT repos/sparkgeo/<repo>/vulnerability-alerts
gh api -X PUT repos/sparkgeo/<repo>/automated-security-fixes
gh api repos/sparkgeo/<repo> --jq '.security_and_analysis'
```

Security-update PRs from Dependabot bypass the weekly schedule and the
cooldown by design.

## Reviewing Dependabot PRs in this repo

- CI must be green; the `Dependency Review` job checks the new version's
  licence and advisories.
- A major bump of an action that changes its runtime (for example
  `actions/checkout` v6 → v7 moving to Node 24) is reviewed on its own PR.
- When a bump touches a reusable workflow, the same pin must also be updated
  in any composite that references the action, so `zizmor` keeps passing.
- Never merge a Dependabot PR whose pinned SHA comment does not match the
  release tag it claims.
