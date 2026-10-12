# Cost gate

Infracost turns every infrastructure pull request into a priced diff (SecOps plan Step 18, issue #91). The gate decides whether that diff may merge; the comment decides whether anyone notices. Both read the same Infracost JSON through `gate.py` in the `infracost` composite, used by `cost-diff-tofu.yml` (#89) and the CDK counterpart (#90).

## Threshold semantics

| Input | Default | Rule |
|---|---|---|
| `max-monthly-increase` | `0` | USD. The job fails when `diffTotalMonthlyCost` is positive and greater than this value. |
| `max-percent-increase` | `0` | Percent of `pastTotalMonthlyCost`. The job fails when the increase divided by the base total exceeds it. A base of $0 with any increase counts as exceeded, because the ratio is undefined. |

- Both at `0` is comment-only (Baseline tier): the diff is posted, nothing blocks.
- Either set alone applies alone; both set means both must pass.
- Decreases and no-change diffs never fail, whatever the thresholds.
- The PR comment ends with one line stating the gate result and the thresholds applied, for example `Cost gate: failed; threshold applied: max monthly increase $100.00 (exceeded); monthly change +$150.00 (+15.0%), new total $1,150.00/month.`
- Resources Infracost cannot price (`totalUnsupportedResources`) are not in the delta; the comment's own summary lists them.

## Recommended values

| Repository class | `max-monthly-increase` | `max-percent-increase` | Why |
|---|---|---|---|
| Client-billed infrastructure | 200 | 10 | Cost changes are passed on; a 10 % drift needs a conversation before merge |
| Internal platforms and shared services | 100 | 25 | Small absolute budgets, larger relative swings expected |
| Sandboxes, previews, demos | 0 | 0 | Comment-only; the environment is torn down anyway |

Set the thresholds in the caller's workflow, not in a repo config, so the values are visible in the same place as the gate.

## Exceptions

A change that must exceed the threshold (a migration, a planned capacity step, a client request) goes through the Step 25 exception process from [`findings-labels.md`](findings-labels.md): open the `security-exception` issue form, state the expected monthly delta and its end date, get the approval recorded there, then merge with the gate raised for that pull request only (`max-monthly-increase` set in a workflow-dispatch input or a temporary caller change that references the exception issue). Exceptions are time-boxed to 90 days like every other finding exception; a permanent new baseline is a threshold change reviewed as code.

## `infracost-usage.yml` conventions

Usage-based resources (S3 storage and requests, data transfer, Lambda invocations, DynamoDB on-demand, CloudWatch logs, NAT gateway traffic) cost $0 in an estimate until usage is declared. The rules:

1. Every IaC repository that declares any of those resources carries an `infracost-usage.yml` at the repository root; `cost-diff-tofu.yml` reads it from the `usage-file` input (default `infracost-usage.yml`).
2. The values are reviewed like code. The file is owned in `CODEOWNERS` by the same team that owns the IaC, so a usage change cannot merge without them.
3. Start from [`examples/infracost-usage.yml`](examples/infracost-usage.yml) and keep the comments: the next reader needs to know where a number came from.
4. When usage-based resources exist and the file is missing, the gate adds a warning to the PR comment and the step summary (`usage-based resources have no usage estimates`). The warning does not fail the job; a missing file in a repo that needs one is a review comment.

Local check of a usage file against a plan:

```bash
infracost breakdown --path plan.json --usage-file infracost-usage.yml --format table
```
