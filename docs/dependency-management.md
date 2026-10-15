# Dependency management

SecOps plan Steps 3 and 7 (issues #86 and #87): every dependency is updated by a bot through a reviewed pull request, immutable references are pinned, and a freshly published version is not pulled into a build until it has sat in the registry for a few days.

## Who updates what

| Ecosystem | Bot | Configured by |
|---|---|---|
| `github-actions` (workflow and action pins) | Dependabot (#87): free on every plan, no infrastructure | `.github/dependabot.yml` in each repository |
| npm, Python (pep621, requirements, pip-compile, poetry), Go modules, Cargo, Terraform providers and modules, Helm charts and values, Kustomize images, Dockerfile and Compose base images, pre-commit hooks | Renovate (#86): one central runner, `autodiscover` over the org | `renovate.json` in each repository extending the shared preset |

The two never touch the same manager, so there are no duplicate PRs: the preset's `enabledManagers` leaves `github-actions` out.

## Opting a repository in

Add `renovate.json` at the root:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>sparkgeo/github-actions"]
}
```

That is all. The central runner ([`renovate.yml`](../.github/workflows/renovate.yml) in this repository, every four hours) finds the repository, reads the preset ([`default.json`](../default.json)) and opens PRs. A repository without `renovate.json` is skipped (`requireConfig: required`, no onboarding PR). The `sparkgeo-renovate` GitHub App must be installed on the repository (org-wide install covers new repositories).

What the preset sets:

| Setting | Value | Why |
|---|---|---|
| `minimumReleaseAge` | `5 days`, with `internalChecksFilter: strict` | The compromised-package window is the first days after publish; Renovate waits for a version old enough instead of opening on the newest one |
| `vulnerabilityAlerts` / `osvVulnerabilityAlerts` | enabled, `minimumReleaseAge: null`, label `security` | A security fix bypasses the cooldown; the weekly review reads it |
| `pinDigests` for `docker` | on | Base images by digest, not tag (immutable references) |
| minor and patch | grouped into one PR | Shorter review queue |
| `lockFileMaintenance` | weekly, Monday before 6am | Transitive updates land in one PR; it inherits no cooldown check of its own, see below |
| `schedule` | weekdays 00:00 to 06:00 America/Vancouver | PRs wait in the morning, not mid-afternoon |

Per-repository overrides go in the same `renovate.json`; the cooldown may be lowered to 3 days or raised to 7:

```json
{
  "extends": ["github>sparkgeo/github-actions"],
  "minimumReleaseAge": "7 days"
}
```

## The cooldown in the package manager

Renovate's cooldown applies to the PRs it opens. Lock-file maintenance, pins and rollbacks carry no release timestamp Renovate can check, and a developer running `npm install` locally is outside Renovate altogether. The package manager enforces the same window at install time:

| Manager | Setting | 5 days |
|---|---|---|
| pnpm | `minimumReleaseAge` in `pnpm-workspace.yaml` (minutes) | `minimumReleaseAge: 7200` |
| npm (11.x) | `min-release-age` in `.npmrc` (days) | `min-release-age=5` |
| uv | `exclude-newer` under `[tool.uv]` in `pyproject.toml` (duration or RFC 3339 timestamp) | `exclude-newer = "5 days"` |
| Dependabot (`github-actions`) | `cooldown.default-days` in `.github/dependabot.yml` | `default-days: 5` |

Each has an exclusion list for a security fix that must land early (`minimumReleaseAgeExclude`, `min-release-age-exclude`, `exclude-newer-package`); use it per package and say why in the commit.

## Running the central runner

- Scheduled every four hours; `workflow_dispatch` takes `dry-run` (`extract`, `lookup` or `full`: nothing is written), `repositories` (run on named repositories instead of autodiscovery) and `log-level`.
- Setup once per org (admin): create the `sparkgeo-renovate` GitHub App with Contents, Pull requests, Issues and Workflows read and write and Metadata read; install it on all repositories; store the App id as the org variable `RENOVATE_APP_ID` and the private key as the org secret `RENOVATE_APP_PRIVATE_KEY`; add `renovatebot/*` to the org actions allowlist ([`approved-actions.md`](approved-actions.md)).
- The preset and the global config are validated in CI with `renovate-config-validator` on every change.
