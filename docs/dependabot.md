# Dependabot: GitHub Actions updates

Dependabot version updates and security updates are free on every GitHub plan
and need no infrastructure. In the Sparkgeo organisation Dependabot owns
exactly one ecosystem for version updates, `github-actions`, in every
repository. The central Renovate runner
([#86](https://github.com/sparkgeo/github-actions/issues/86)) owns version
updates for everything else, so no dependency gets version-update PRs from both.
Dependabot security updates still cover every ecosystem (see
[Security updates and alerts](#security-updates-and-alerts)); when one arrives
for a package Renovate also bumps, merge whichever PR comes first and close the
other.

| Ecosystem | Tool | Why |
|---|---|---|
| `github-actions` (SHA-pinned `uses:` references in workflows and composite actions) | Dependabot | Native, zero infrastructure, understands SHA pins and keeps the `# vX.Y.Z` comment current |
| npm, pip, Go modules, Cargo, Maven | Renovate | One runner, one config, grouped and scheduled across repos |
| Terraform / OpenTofu providers and modules | Renovate | `terraform` manager |
| Helm chart dependencies, `values.yaml` image tags, Kustomize images | Renovate | `helmv3`, `helm-values`, `kustomize` managers |
| Dockerfile base images (tag and digest) | Renovate | `dockerfile` manager with `pinDigests: true` (plan Step 24). `container-lint.yml` ([#13](https://github.com/sparkgeo/github-actions/issues/13), PR [#142](https://github.com/sparkgeo/github-actions/pull/142)) adds a check that fails a `FROM` line without a digest; hadolint's DL3006 and DL3007 only require a tag |
| Images in workflow `container:`, `services:` and `docker://` references | Renovate | Renovate's `github-actions` manager finds these images too. The preset (#86) must turn off only the action updates for that manager (a `packageRules` entry on its action datasources), not the whole manager, or these images are bumped by neither tool |

## Reference `.github/dependabot.yml` for consuming repos

Copy as is; it is the same as this repo's own config.

- `directories` covers workflows (`/`) and every composite action under
  `.github/actions/`. A glob that matches nothing is ignored, so repos without
  composites can keep it.
- `cooldown` lets a release settle for 7 days before it is proposed. This is
  inside the plan's 3 to 7 day range (Step 3 Baseline); the Renovate preset
  (#86) is to set the matching `minimumReleaseAge: "7 days"`.
- The group with `group-by: dependency-name` opens one PR per action per week,
  covering every directory that pins it. Without `group-by`, Dependabot opens a
  separate PR for each directory. A major bump is still its own PR, because
  each PR holds one action.
- No `labels` key: Dependabot's defaults are `dependencies` and
  `github_actions`, and setting `labels` would replace both.

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    # "/" covers .github/workflows only; composites need their own directories.
    directories:
      - "/"
      - "/.github/actions/*"
    schedule:
      interval: "weekly"
    cooldown:
      default-days: 7
    groups:
      actions:
        group-by: dependency-name
    commit-message:
      prefix: "ci"
```

Do not add other `package-ecosystem` entries; Renovate covers them. A repo
that is not yet onboarded to Renovate may add them temporarily and must
remove them when it is.

## Security updates and alerts

Dependabot alerts and security updates are separate from version updates and
apply to every ecosystem in the dependency graph, including the ones Renovate
manages. They should be on for every repository. Security-update PRs bypass the
weekly schedule and the cooldown by design.

**They do not cover SHA-pinned actions.** GitHub raises alerts for actions only
when the reference is a semantic version, not a commit SHA, and every action in
this organisation is SHA-pinned. A vulnerable action is caught instead by
zizmor's `known-vulnerable-actions` audit, which the `zizmor` composite runs
online with the job's `GITHUB_TOKEN` and reports to the Security tab. Its fix
still arrives as an ordinary version update, after the cooldown. For an urgent
fix, bump the pin by hand (the SHA check below applies) instead of waiting.

**Organisation level (owner, UI):** Settings → Advanced Security (Code
security on older UIs) → Configurations. Apply a security configuration with
Dependency graph, Dependabot alerts and Dependabot security updates enabled to
all repositories, set it as the default for new repositories, and set it to
enforce so repository admins cannot turn the features off. Repositories
transferred into the organisation need the configuration applied by hand.

**Repository level (admin, API):**

```bash
REPO=sparkgeo/my-repo
gh api -X PUT "repos/$REPO/vulnerability-alerts"
gh api -X PUT "repos/$REPO/automated-security-fixes"
gh api "repos/$REPO" --jq '.security_and_analysis'
```

## Reviewing Dependabot PRs in this repo

- CI must be green. For an action bump, the check that matters is `zizmor`;
  the `Dependency Review` job gives no advisory signal for SHA-pinned actions.
- A major bump arrives as its own PR. Read the release notes for a changed
  runtime (for example a new Node version) or changed inputs before merging.
- Every commit on the PR is authored by `dependabot[bot]`. A commit from anyone
  else gets a normal code review.
- The pinned SHA matches the release tag in its `# vX.Y.Z` comment. Check
  each pin in the PR:

  ```bash
  gh api repos/OWNER/ACTION/commits/vX.Y.Z --jq .sha
  ```

  The cooldown, not this check, is the defence against a tag that is moved
  after release.
