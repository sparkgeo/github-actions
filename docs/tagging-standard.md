# Tagging standard

Every cloud resource and Kubernetes workload Sparkgeo runs carries the same four tags, so cost, ownership, blast radius and data handling can be answered from inventory alone (SecOps plan Step 31, issue #114). The machine-readable standard is [`policies/tags/standard.yml`](../policies/tags/standard.yml); this page explains it.

## Required tags

| Key | Values | Purpose |
|---|---|---|
| `owner` | `team-<name>` or `<user>@sparkgeo.com` (Kubernetes labels: `<user>_at_sparkgeo.com`) | Who is paged and who approves changes |
| `project` | 3 to 40 characters, lowercase letters, digits and hyphens | Groups resources for cost and inventory |
| `environment` | `dev`, `staging`, `prod`, `shared` | Drives backup tier, retention and change control; `shared` is for cross-environment infrastructure such as CI runners and registries |
| `data-class` | `public`, `internal`, `confidential`, `restricted` | Highest tier the resource stores or processes, per the [data classification policy](data-classification.md) (issue #100) |

Optional: `cost-center` (when billing is split below project level) and `client` (billable client resources).

Tags are lowercase keys. Values are literal where the enforcement point can see them; a Terraform variable or a CDK token is accepted at lint time and must be checked by the environment that resolves it.

## Where it is enforced

| Stack | What checks it | What happens on a miss |
|---|---|---|
| Terraform / OpenTofu, AWS | tflint `aws_resource_missing_tags` with [`policies/tags/tflint/aws.tflint.hcl`](../policies/tags/tflint/aws.tflint.hcl), run as a second pass by the `tflint` composite (`require-tags`). A `provider "aws"` block with `default_tags` covering the four keys satisfies every resource | Inline annotation per resource, job fails |
| Terraform / OpenTofu, Azure | tflint `azurerm_resource_missing_tags` with [`azurerm.tflint.hcl`](../policies/tags/tflint/azurerm.tflint.hcl) (`tags-provider: azurerm`); Azure has no provider-level default tags | Same |
| Terraform / OpenTofu, providers | checkov `SPK_TAG_1` (AWS `default_tags`) and `SPK_TAG_2` (Google `default_labels`) in [`policies/tags/checkov/`](../policies/tags/checkov) | Failed check in the checkov report |
| Terraform / OpenTofu, GCP resources | No tflint rule exists in the Google ruleset; rely on `SPK_TAG_2` and provider `default_labels` | |
| Helm / Kustomize | `tags.rego` in the k8s-policy bundle, loaded with the standard as data when `require-tags` is on: labels on `Pod`, `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `Job`, `CronJob` and `Namespace` | Deny per missing or invalid label, job fails |
| AWS CDK | `RequiredTagsAspect` ([Python](examples/cdk/required_tags_aspect.py), [TypeScript](examples/cdk/required-tags-aspect.ts)) applied to each stack; reads the tags resolved by `Tags.of(stack).add(...)` | Error annotation per resource, `cdk synth` fails |

## Adopting it

- Terraform: add `default_tags` (AWS) or `default_labels` (Google) to every provider block; Azure resources tag individually or through a shared `locals.tags` map.
- Helm: put the four labels in `metadata.labels` of every workload template and namespace, sourced from `values.yaml` so each release sets them once.
- CDK: `Tags.of(stack).add(key, value)` for the four keys, then `RequiredTagsAspect.apply(stack)`.
- Turning the gate off (`require-tags: false`) is a reviewed exception, not a default; record the reason in the calling workflow.

## Changing the standard

Edit `policies/tags/standard.yml`, then keep the mirrors in step: the tflint `tags` lists, the checkov policy attributes, and `REQUIRED` in the two CDK aspect files. `tests/tagging/run.sh` exercises every enforcement point against pass and fail fixtures.
