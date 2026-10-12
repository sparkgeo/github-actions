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

`inventory.dot` and `inventory.svg` (Graphviz, rendered when `dot` is available, which it is on GitHub-hosted runners) cluster resources project, environment, owner. Fill colour follows `data-class`: public green, internal blue, confidential yellow, restricted red, unclassified grey; a resource with `tag_violations` gets a red border. `inventory.mmd` is the same grouping as a Mermaid `flowchart` and is embedded in the PR comment while the inventory has at most `mermaid-max-nodes` resources.

## Publishing

On a push to the default branch, `asset-inventory.yml` uploads `inventory.json`, `inventory.svg`, `inventory.mmd` and `SHA256SUMS` to the rolling `asset-inventory-latest` release of the calling repository (the caller grants `contents: write`). Pull requests download that `inventory.json` as the diff base. An org-wide roll-up reads each repository's release.

## Topology add-ons (not wired)

The register is a flat list grouped by tags; it does not draw dependencies. When a topology view is needed, two tools produce one from the same inputs and can run as an extra step in the caller:

- `inframap` reads the OpenTofu plan or state and draws provider-aware connection graphs (`inframap generate plan.json | dot -Tsvg`).
- `cdk-dia` draws CDK construct trees from `cdk.out` (`npx cdk-dia`).

Both need their own installs and egress; neither is part of the composite.
