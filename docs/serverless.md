# Serverless scan

`serverless-scan.yml` is the PR gate for Lambda stacks (issue #183, SecOps plan Step 17 Standard): one least-privilege role per function, deployment packages and layers scanned for known vulnerabilities, function logs in a declared group with retention, and a dead-letter queue for asynchronous failures. `iac-scan.yml` checks the template against the general checkov set; this workflow adds what the general set does not see, the zip and the role sharing.

## Usage

```yaml
jobs:
  serverless:
    permissions:
      contents: read
      security-events: write  # drop when sarif-upload: false
    uses: sparkgeo/github-actions/.github/workflows/serverless-scan.yml@<SHA>
    with:
      directory: infra            # Terraform, or the template directory
      framework: cloudformation   # for SAM, CloudFormation and cdk.out
      template-path: cdk.out      # JSON templates for the shared-role check
      package-glob: cdk.out/asset.*.zip
      actions-ref: <SHA>          # same SHA as above
```

Build the stack before the job (`sam build`, `cdk synth`, `serverless package`, or your own zip step) so the packages exist. Without a matching package the job says so and runs the policy checks only.

## What is checked

| Check | Where | Meaning |
|---|---|---|
| `SPK_SLS_1` | `policies/serverless/spk_sls_1.yaml` | The function references a role declared in the same configuration, not a hand-made ARN string. Graph policies cannot count references, so a role shared by several functions is caught by `serverless-roles.py` over JSON templates (`template-path`), one error per shared role. YAML templates are skipped with a notice: point at the JSON output of `sam build` or `cdk synth`. Terraform has no equivalent yet |
| `CKV_AWS_287` to `CKV_AWS_290`, `CKV_AWS_355`, `CKV_AWS_356` (Terraform); `CKV_AWS_107` to `CKV_AWS_111` (CloudFormation) | checkov built-ins | No wildcard actions or resources, no privilege escalation, no credential exposure in the function's policy |
| `SPK_SLS_3` | `policies/serverless/spk_sls_3.yaml` | The function logs to a declared log group (`logging_config` / `LoggingConfig`) instead of the unlimited default group Lambda creates on first invocation |
| `CKV_AWS_66` | checkov built-in | The log group sets `retention_in_days` / `RetentionInDays` (plan Step 9) |
| `CKV_AWS_116` | checkov built-in | Dead-letter queue configured (the issue's `SPK_SLS_4`) |
| `CKV_AWS_115`, `CKV_AWS_45`, `CKV_AWS_173` | checkov built-ins | Concurrency limit; no hard-coded secrets in the environment; environment encrypted with a CMK |
| Packages | trivy `fs --scanners vuln` over every unzipped package and layer | Vulnerabilities in vendored dependencies (`requirements.txt`, `package-lock.json`, site-packages, `node_modules`); fails at or above `fail-on-severity`, one SARIF per run |

`require-per-function-role: false` drops `SPK_SLS_1` and the shared-role failure; `require-log-retention: false` drops `SPK_SLS_3` and `CKV_AWS_66`. The checkov gate follows `policy-fail-on-severity` (`high` by default, the vocabulary in `docs/gate-policy.md`); the package gate follows `fail-on-severity` (`critical` by default).

## Not automated

- **IAM Access Analyzer policy generation**: generate the least-privilege policy per function from CloudTrail in the console or with `aws accessanalyzer start-policy-generation`, then commit it. The checks above verify the result, not the generation.
- **Handler-boundary input validation**: event-source payloads are validated in code; a review item, not a scan.
- **GCP Cloud Functions and Azure Functions**: no fixtures yet; the policies name AWS resource types only. Add the equivalents when the first such repository appears.

## Local run

```bash
CHECKS="$(grep -oE '^[A-Z_0-9]+' policies/serverless/checks.txt | paste -sd, -),SPK_SLS_1,SPK_SLS_3"
checkov -d infra --framework terraform --external-checks-dir policies/serverless --check "$CHECKS"
python3 -I .github/actions/checkov/serverless-roles.py --template cdk.out --fail
trivy fs --scanners vuln dist/unzipped-package
```

`tests/serverless-scan/run.sh` runs all three over the fixtures under `tests/serverless-scan/fixtures` (a Terraform and a CloudFormation pass and fail stack, a template with a shared role, a requirements file with known CVEs).
