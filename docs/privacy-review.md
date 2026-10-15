# Privacy review gate

SecOps plan Step 36 Standard (issue #121): "a privacy review gate in the S-SDLC for features touching personal or location data". `privacy-review-gate.yml` decides on every pull request whether privacy review is needed and, when it is, blocks the merge until it has happened.

## When review is needed

Any one of:

1. A changed path matches `privacy-paths` (default: `ropa.yml`, `retention.yml`, `**/migrations/**`, `**/models/**`, `**/schemas/**`, `**/schema/**`, `**/*.sql`) or is an IaC or code file that names a store listed in `ropa.yml` (#119).
2. The privado data-flow report for the PR's head (the `privado-report` artefact from `pii-dataflow.yml`, #99) lists a new data element, sink or third-party destination relative to the default branch.
3. The author filled in the PR body's `## Privacy impact` section (self-declaration; an empty section or `N/A` does not count).

## What the gate requires

- the label `privacy-review` on the PR;
- an approving review on the current head commit from a member of `privacy-owner` (default team `sparkgeo/privacy`), read through the API: a later "changes requested" revokes it, an approval of an earlier commit is stale;
- a PIA link in the PR body matching `pia-link-pattern` (default `docs/pia/`), the file produced from [`pia-template.md`](pia-template.md).

The comment on the PR lists the trigger and what is missing; it updates in place and the check re-runs on every review event. A PR that does not need review passes with a note.

## Reading the privacy owner team

The job's `GITHUB_TOKEN` cannot list organisation teams. Either pass a token with `members:read` on the org as the `reviewer-token` secret, or give the reviewer logins in `privacy-reviewers`. With neither, a triggered PR fails and says so.

## Consuming

```yaml
# .github/workflows/privacy-review.yml
name: Privacy Review
on:
  pull_request:
  pull_request_review:        # re-evaluate when the reviewer approves
jobs:
  gate:
    permissions:
      contents: read
      pull-requests: write    # the comment
      actions: read           # the privado-report artefact
    uses: sparkgeo/github-actions/.github/workflows/privacy-review-gate.yml@<SHA>
    with:
      actions-ref: <SHA>      # same SHA as above
      # privacy-reviewers: alice,bob
      # privacy-paths: ropa.yml,retention.yml,**/migrations/**,services/api/models/**
    secrets:
      reviewer-token: ${{ secrets.PRIVACY_TEAM_READ_TOKEN }}   # optional
```

Never run the gate from `pull_request_target`: the token must stay read-only on the repository.

## PR template section

Add to `.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## Privacy impact

<!-- Fill in when the change touches personal or location data; otherwise leave as is.
     What data, whose, why; where it is stored, logged, sent; retention. Link the PIA: docs/pia/<activity>.md -->
N/A
```

## CODEOWNERS

```text
/ropa.yml          @sparkgeo/privacy
/retention.yml     @sparkgeo/privacy
/.pii-allowlist.yml @sparkgeo/security
**/migrations/**   @sparkgeo/privacy
/docs/pia/         @sparkgeo/privacy
```

CODEOWNERS makes the team a requested reviewer; the gate checks that the approval actually came from the team, so a repository where the owners file was bypassed still blocks.

## Ruleset

At Standard tier (#84) add the check `Privacy Review / Privacy review` to the branch ruleset's required status checks for the default branch, with "dismiss stale pull request approvals when new commits are pushed" on, so the gate's on-head rule and the platform agree. At Baseline the workflow runs but is not required.
