# Asset inventory

`inventory.json` is the per-repository asset register produced by the `asset-inventory` composite and published by `asset-inventory.yml` (SecOps plan Step 31, issue #115). It answers "what do we run, where, and who owns it" from plan and synth output, before anything is deployed. The JSON Schema is [`asset-inventory.schema.json`](asset-inventory.schema.json).

## Document

| Field | Meaning |
|---|---|
| `generated_at` | UTC time of the run |
| `repo` | `owner/name` the plans came from |
| `stack_kind` | `tofu` or `cdk` |
| `required_tags` | tag keys checked for `tag_violations`; defaults to the [tagging standard](tagging-standard.md) |
| `counts` | `resources`, `taggable`, `violations` (resources missing at least one required tag) |
| `resources` | one record per resource, sorted by `stack` then `id` |
| `diff` | present on pull requests: `added`, `removed` (ids) and `retagged` (`id`, `key`, `before`, `after`) against the last published inventory |

## Resource record

```json
{ "id": "module.net.aws_subnet.private[0]", "type": "aws_subnet", "name": "private",
  "stack": "stacks/prod", "account": null, "region": "us-west-2", "taggable": true,
  "tags": { "owner": "team-platform", "project": "prescient", "environment": "prod", "data-class": "confidential" },
  "tag_violations": [],
  "source": { "repo": "sparkgeo/prescient-infra", "path": null, "line": null } }
```

| Field | OpenTofu | CDK |
|---|---|---|
| `id` | full address: module path, `for_each` key or `count` index included | CloudFormation logical id |
| `type` | provider resource type (`aws_s3_bucket`) | CloudFormation type (`AWS::S3::Bucket`) |
| `stack` | directory of the plan file under the input directory | template file name without `.template.json` |
| `region` | `region` of the resource's provider configuration | null (templates are region-agnostic) |
| `account` | from the `account` input, else null | same |
| `taggable` | the type exposes `tags`, `tags_all`, `labels` or `effective_labels` | a common taggable type, or `Properties.Tags` present |
| `tags` | `tags_all`, else `tags`, else `effective_labels`, else `labels` | `Properties.Tags` |
| `source.path` | null: plan JSON carries no source positions | `Metadata["aws:cdk:path"]` |

Data sources, `AWS::CDK::Metadata` and anything that is not a managed resource are left out. `tag_violations` lists only missing keys; a value outside the standard's enum is the tagging gate's finding, not the register's.

## Diagram

`inventory.dot` and `inventory.svg` (Graphviz; the composite installs the `graphviz` package with apt when `dot` is missing, as it is on current GitHub-hosted images) cluster resources project, environment, owner. Fill colour follows `data-class`: public green, internal blue, confidential yellow, restricted red, unclassified grey; a resource with `tag_violations` gets a red border. `inventory.mmd` is the same grouping as a Mermaid `flowchart` and is embedded in the PR comment while the inventory has at most `mermaid-max-nodes` resources.

## Publishing

On a push to the default branch, `asset-inventory.yml` uploads `inventory.json`, `inventory.svg`, `inventory.mmd` and `SHA256SUMS` to the rolling `asset-inventory-latest` release of the calling repository (the caller grants `contents: write`). Pull requests download that `inventory.json` as the diff base. An org-wide roll-up reads each repository's release.

## Org-wide register

`asset-register-rollup.yml` in `sparkgeo/github-actions` merges every repository's `asset-inventory-latest` inventory once a day (issue #116) and publishes:

| File | Content |
|---|---|
| `assets.json` | `generated_at`, `stale_days`, `repos` (one row per repository: `generated_at`, `stack_kind`, `resources`, `violations`, `age_days`, `stale`), `counts` (`repos`, `assets`, `unowned`, `stale_repos`) and `assets`: every resource record from the inventories with `repo` and `unowned_reason` added |
| `owners.md` | assets per owner, project and environment |
| `unowned.md` | assets with tag violations or a `team-*` owner that is not in `policies/tags/teams.yml`; `<user>@sparkgeo.com` owners pass |
| `data-classes.md` | confidential and restricted assets with type, owner, stack and region |
| `register.dot`, `register.svg` | the org diagram, nodes labelled with their repository |
| `summary.md` | the text posted to the tracking issue |
| `SHA256SUMS` | checksums of the files above |

Releases: `asset-register-latest` (rolling) and `asset-register-YYYY-MM-DD` (90 retained). An inventory older than seven days is stale and listed in the summary; a repository whose `SHA256SUMS` does not verify is skipped with a warning. The tracking issue "Asset register: unowned or stale assets" stays open until a run finds nothing.

**Auditors.** A dated snapshot is the evidence for that day:

```bash
gh release download asset-register-2026-10-12 -R sparkgeo/github-actions -D register-2026-10-12
cd register-2026-10-12 && sha256sum -c SHA256SUMS
```

**App setup (org admin).** Create a GitHub App with repository permissions `Contents: read` and `Metadata: read`, install it on all repositories, and store its id and private key as the `ASSET_REGISTER_APP_ID` and `ASSET_REGISTER_APP_PRIVATE_KEY` secrets of `sparkgeo/github-actions`. The workflow mints a short-lived token per run with `actions/create-github-app-token`; without the secrets it falls back to `GITHUB_TOKEN` and sees public repositories only.

## Topology add-ons (not wired)

The register is a flat list grouped by tags; it does not draw dependencies. When a topology view is needed, two tools produce one from the same inputs and can run as an extra step in the caller:

- `inframap` reads the OpenTofu plan or state and draws provider-aware connection graphs (`inframap generate plan.json | dot -Tsvg`).
- `cdk-dia` draws CDK construct trees from `cdk.out` (`npx cdk-dia`).

Both need their own installs and egress; neither is part of the composite.
