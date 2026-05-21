# Contributing

This repo is the central library of reusable GitHub Actions workflows for the Sparkgeo organisation. All contributions must meet the security standards below before a PR can be merged.

## Workflow authoring checklist

Every PR that adds or modifies a workflow or composite action must satisfy all of the following:

```
[ ] All `uses:` references pinned to a full 40-character commit SHA with a # version comment
    e.g. uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

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

[ ] All `run:` steps declare `shell: bash` explicitly

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
gh api repos/actions/checkout/commits/v4 --jq '.sha'
```

Renovate (issue #8) is configured to keep pinned SHAs current automatically via automated PRs — do not update SHAs manually unless fixing a security incident.

## Adding a new workflow

1. Create a GitHub issue (parent + context sub-issues where applicable)
2. Assign to `ms280690`, type: Feature, labels: `security`, `enhancement`, `documentation`, `priority: high`
3. Branch from `main`: `git checkout -b issue-<number>-<short-description>`
4. Implement the workflow — satisfy all checklist items above
5. Update the workflow index table in `README.md`
6. Open a PR referencing the issue: `Closes #<number>`

## Security pillars reference

| Pillar | Issue | Summary |
|---|---|---|
| Workflow authoring standards | #25 | This checklist; `actionlint`/`zizmor` gate |
| Supply chain hardening | #26 | SHA pinning policy; org allowlist; dependency locking |
| OIDC & secret federation | #27 | No static credentials; OIDC for cloud auth; environment-scoped secrets |
| Runner egress control | #28 | `harden-runner` audit → block; self-hosted runner isolation policy |
| Governance & observability | #29 | Org rulesets; audit log → SIEM; OpenSSF Scorecard |

## Reporting a security vulnerability

Do not open a public issue for security vulnerabilities. Use the [Security Advisory](../../security/advisories/new) process via the Security tab of this repo.
