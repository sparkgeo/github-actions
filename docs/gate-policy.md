# Gate policy: one severity vocabulary for every scanner

Every scanning workflow in this repo that can block a merge takes the same
input, `fail-on-severity`, with the same five values. A consuming repo sets one
posture and it means the same thing in every gate. This implements the Findings
SLA framework (SecOps plan Step 25): the same signal always produces the same
gate, across all tools and all teams.

## Vocabulary

| `fail-on-severity` | Fails when the highest finding is… | SLA row (plan Step 25) |
|---|---|---|
| `critical` | CVSS ≥ 9.0 | Critical: 48 h production, 7 days non-production |
| `high` | CVSS ≥ 7.0 | High: 7 days, 30 days |
| `medium` | CVSS ≥ 4.0 | Medium: 30 days, 90 days |
| `low` | CVSS ≥ 0.1 | Low: 90 days or next maintenance |
| `none` | never; findings are reported, the job passes | advisory rollout only |

`moderate` is accepted as an alias for `medium` because `actions/dependency-review-action`
uses that word natively. New workflows must not introduce other aliases.

Defaults follow the plan's Baseline tier: `critical` for dependency and container
scanners, `high` for lint-style tools whose findings are configuration errors
rather than CVEs. A consuming repo tightens by passing a lower value.

## Mapping for tools without CVSS

Lint-style scanners report levels, not scores. They map as follows and the
composite does the translation, so callers never see the tool-native word.

| Tool level | Canonical |
|---|---|
| `error` | `high` |
| `warning` | `medium` |
| `notice` / `info` | `low` |

So `fail-on-severity: high` on `lint-iac.yml` means "fail on tflint errors",
and `medium` means "fail on warnings too".

## Secrets are not configurable

A secret finding is always blocking, in every environment, at every tier
(plan Step 25 Baseline: "secrets always hard-blocked"). `secrets-precommit.yml`
and `secrets-scan.yml` therefore take no `fail-on-severity`. Their inputs
control *what counts as a finding*, not how severe it is:

| Workflow | Input | Meaning |
|---|---|---|
| `secrets-precommit.yml` (gitleaks) | `fail-on-finding` (default `true`) | `false` reports without blocking. Allowed only for a time-boxed advisory rollout on a repo with a pre-existing history to clean; never on a repo at Standard tier or above. |
| `secrets-scan.yml` (trufflehog) | `only-verified` (default `true`) | `true` blocks on verified live credentials and warns on unverified matches; `false` blocks on both. |

## Implementation

Tools with a native threshold (`actions/dependency-review-action`, tflint) get
the canonical value translated inside their composite. Tools with no native
gate (osv-scanner today; grype and trivy when added) hand their findings file to
the shared `severity-gate` composite, which emits one annotation per affected
package, exposes `max-score` and `max-severity` outputs, and applies the table
above. Its script is `.github/actions/severity-gate/gate.sh`; its tests are
`tests/severity-gate/run.sh`, run in CI.

| Workflow / composite | Native gate | How the vocabulary is applied |
|---|---|---|
| `dep-scan-app.yml` / `osv-scanner` | no | `severity-gate`, format `osv-json` |
| `lint-iac.yml` / `tflint` | `--minimum-failure-severity` | mapped in the composite; `minimum-failure-severity` input kept as a deprecated alias |
| `dependency-review` | `fail-on-severity` + `vulnerability-check` | `medium` → `moderate`; `none` → `vulnerability-check: false` |
| `secrets-precommit.yml`, `secrets-scan.yml` | n/a | not configurable, see above |
| `lint-app.yml` (MegaLinter), `lint-helm.yml` (kubeconform) | n/a | any error blocks; these are correctness checks, not severity-ranked findings |

## Adding a new scanner

1. Expose `fail-on-severity` with exactly the five values above and a default
   from the Baseline tier.
2. If the tool scores findings, write a `format` reader for `severity-gate`
   and add fixtures to `tests/severity-gate/`.
3. If the tool reports levels, map them in the composite using the table above
   and document the mapping in the input description.
4. Never add a second severity input with a different name.

Advanced-tier overrides (EPSS ≥ 0.10 or CISA KEV uplift to `critical`) are
tracked in #80 and plug in ahead of `severity-gate`.
