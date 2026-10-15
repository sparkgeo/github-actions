# Sigma detection rules: lint, test case, conversion

SecOps plan Step 9 Standard and Step 40 (issue #177): detection rules are kept as Sigma in git, validated in CI, converted to the SIEM on merge, and each carries a test case that must fire under emulation. A rule that only exists in the SIEM console has no review, no history and no proof it fires. `sigma-lint.yml` is the gate; `sigma-cli` with a pySigma backend does the checking and the conversion.

## Layout in a consuming repository

```text
detections/
  rules/<name>.yml        Sigma rules, one per file
  tests/<rule id>.yml     one test case per rule, keyed by the rule's id
```

## Test-case schema

File: `<tests-dir>/<rule id>.yml`. Without a valid one the rule is unproven and the lint fails (`require-test-case`, default on). This is the schema in [`docs/validation.md`](validation.md) section 7 (#176).

```yaml
technique: T1098.003          # ATT&CK technique id the rule detects
source: stratus:aws.persistence.iam-create-admin-user
#   atomic:<test guid>        Atomic Red Team test, run by hand or by Invoke-AtomicRedTeam
#   stratus:<technique id>    Stratus Red Team technique, run by stratus-red-team.yml (#178)
#   manual                    Described in `steps`; run by a person
expect: detected              # detected or prevented; the outcome the next run must record
steps: |                      # manual sources only
  Create an IAM user with AdministratorAccess from a non-admin session.
```

Checks: `technique` matches `T####` or `T####.###`; `source` is `atomic:<36-character guid>`, `stratus:<technique id>` or `manual`; a `manual` source has non-empty `steps`; `expect` is `detected` or `prevented`. A test case whose id matches no rule is a warning (orphan). The `stratus:` sources are what `stratus-red-team.yml` (#178) runs.

## What runs

| Step | Command | Result |
|---|---|---|
| Install | `python3 -m venv` + `pip install sigma-cli==3.1.0 pysigma-backend-<backend>` (pin it with `backend-package`) | PyPI is the only egress |
| Check | `sigma check --junitxml` over `rules-dir` | rule errors (parse, identifier, condition) are PR annotations and fail the job; validator issues (naming, best practice) are warnings. The `attacktag` and `d3_fendtag` validators are skipped (`exclude-validators`): they download MITRE ATT&CK and D3FEND data from GitHub at run time, and the test-case check validates technique ids offline |
| Test cases | [`check.py`](../.github/actions/sigma-lint/check.py) | schema above; missing or malformed fails with `require-test-case` |
| Convert | `sigma convert -t <backend> [-p <pipeline>] --skip-unsupported` per rule into one file each | a failed conversion is an error; on a PR this is a dry run, on the default branch the directory is uploaded as the artefact `sigma-<backend>` |
| Summary | job summary | rule count, rules per `logsource` product, rules without a test case, conversion failures, rules whose `modified` (or `date`) is older than 365 days (`stale-days`) |

Backend identifiers are pySigma plugin ids (`sigma list targets` after install): `splunk`, `elasticsearch`, `opensearch`, `kusto` (Microsoft Sentinel), `secops` (Google SecOps, formerly Chronicle), `loki`, `crowdstrike`, and others from `sigma plugin list`. `none` skips conversion. Backends that require a processing pipeline (Splunk does) convert `--without-pipeline` when `pipeline` is empty; set `pipeline` to an identifier from `sigma list pipelines <backend>` or a YAML file in the repository for field mapping.

## Hand-off to the SIEM

The artefact `sigma-<backend>` holds one query file per rule (`<rule file stem>.txt`). The consuming repository's push job (per SIEM, outside this repository) downloads it on the default branch and creates or updates the saved searches. The rule file name is the stable key; the Sigma `id` is inside the rule.

## Consuming

```yaml
jobs:
  sigma-lint:
    permissions:
      contents: read
    uses: sparkgeo/github-actions/.github/workflows/sigma-lint.yml@<SHA>
    with:
      actions-ref: <SHA>       # same SHA as above
      backend: splunk
      backend-package: pysigma-backend-splunk==2.1.0
      # pipeline: splunk_cim
      # rules-dir: detections/rules
      # tests-dir: detections/tests
```

## Tested

[`tests/sigma-lint/run.sh`](../tests/sigma-lint/run.sh) runs `sigma check` and `check.py` on a fixture set with one passing rule and test case, one rule whose id is not a UUID, one rule with no test case (and stale), an orphan test case, malformed test cases of each kind, splunk conversion with one failure, and the `require-test-case` switch. The CI job runs it, then the composite over the clean fixture with the splunk backend and uploads `sigma-splunk` on the default branch.
