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
`tests/severity-gate/run.sh` and `tests/osv-scanner/run.sh` (recorded
osv-scanner 2.4.0 output), run in CI.

One exception to the severity table: an OpenSSF malicious-package advisory
(`MAL-*` in osv-json) has no CVSS score, so no threshold would ever block it.
With `fail-on-malicious: true` (the default) the gate fails on any such
advisory whatever `fail-on-severity` says; an empty `max_severity` reads as 0.

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

## Likelihood override (EPSS, KEV, LEV)

Advanced tier, opt-in with `epss-override: true` on `dep-scan-app.yml`. The
`epss-kev-override` composite rewrites the findings file ahead of
`severity-gate`, so the gate itself is unchanged. CVSS sets the row; these
move it (plan Step 25, Remediation SLA Table):

| Rule | Condition, per advisory (all its CVE aliases) | Effect |
|---|---|---|
| Up | EPSS ≥ `epss-threshold` (default 0.10), or on CISA KEV, or NIST LEV ≥ 0.5 (counts as a KEV hit) | critical (9.0) |
| Down, `downgrade: true` | CVSS high or critical, and every CVE has EPSS < 0.01, is not on KEV, and has LEV < 0.1 | one row down |
| Runtime relevance, `runtime-relevance-file` | every CVE is `relevant: false` for that package in the #179 export | one row down, after the others |

A moved finding takes the floor score of its new row (9.0, 7.0, 4.0, 0.1), and
each of its advisories the matching `database_specific.severity` label, which
DefectDojo's OSV parser reads (#185); low
does not drop further. Modifiers stack, so a KEV-listed CVE in a package the
workload never loads lands at high. `MAL-*` advisories have no CVE and pass
through untouched, so `fail-on-malicious` still blocks them.

**Data.** KEV and EPSS come from the #109 mirror (`threat-feeds` composite), so
the job reaches only GitHub. Each adjusted finding keeps an `override` object:
the original score, the rules applied, per-CVE EPSS, percentile, KEV
`dateAdded` and LEV, the snapshot tag, and the SSVC decision points the data
supports (`exploitation: active` when on KEV; `automatable: yes` when a CVSS
vector is `AV:N/PR:N/UI:N`) for the DefectDojo import (#185). Re-running with
`feeds-ref` set to the snapshot date reproduces the row.

**LEV source.** NIST has not published LEV as a feed, so the composite computes
it from the mirror's dated EPSS snapshots with the CSWP 41 formula:
`LEV = 1 − ∏ (1 − EPSS(dᵢ) × wᵢ)` over dᵢ every 30 days from the oldest
snapshot to today, wᵢ = 1 for a full window and (days left)/30 for the last.
`dep-scan-app.yml` fetches the snapshots 30 and 60 days back. The mirror keeps
90 days, so LEV here is a lower bound over that window (the paper's LEV is
also a lower bound). With no older snapshot LEV is unknown: nothing is
raised on LEV and nothing is downgraded.

The SARIF uploaded to the Security tab keeps the tool's own scores; the job
summary lists every finding that moved and why.

## DefectDojo hand-off

The gate decides whether a pull request merges; DefectDojo (Step 25 Standard)
is where the findings wait to be fixed. One queue across repositories, a
deadline that starts at triage, and the same CVE from trivy, grype and
osv-scanner deduplicated. The `defectdojo-import` composite re-imports a
findings file with `POST /api/v2/reimport-scan/`; `dep-scan-app.yml` and
`secrets-scan.yml` call it behind `defectdojo: true`, and every new scan
workflow does the same.

| Setting | Value |
|---|---|
| Product / engagement / test | the repository name / `ci` / one test per scan type, created on first import (`auto_create_context`) |
| Re-import | deduplicates against that test; findings missing from the new file are closed (`close_old_findings`): the **Fix** outcome |
| Severity | the file as the gate saw it: the `epss-kev-override` output when `epss-override` is on, so the queue carries the adjusted row and the `override` annotations |
| Environment | `production` or `staging` etc. as the DefectDojo environment and an `env:` tag |
| Not configured | `DEFECTDOJO_URL` or `DEFECTDOJO_TOKEN` unset: skipped with a summary line |

**Root-cause tags.** Pass `tags` so one change can close many findings, and
order the fix queue by findings removed per change:

| Tag | Use for |
|---|---|
| `base-image:<digest>` | every container finding inherited from one base image |
| `iac-module:<path>` | every IaC finding from one shared module |
| `dependency:<name>` | every finding fixed by bumping one package |
| `chokepoint:<id>` | the permission, group or credential most attack paths run through (Step 40) |

**SLA.** DefectDojo counts SLA in whole days. `docs/defectdojo-sla-setup.sh`
creates two SLA configurations from the table above, "Sparkgeo production"
(critical 2 days, high 7, medium 30, low 90) and "Sparkgeo non-production"
(7, 30, 90, 90), and assigns one to each named product. Secrets have no row
there: they are hard-blocked in CI and rotated at once.

**Decision outcomes (#81).** Fix is recorded by the re-import that no longer
reports the finding. Mitigate, Monitor and Accept are DefectDojo risk
acceptances with the evidence note and an expiry; the import keeps them
accepted (`do_not_reactivate`).

