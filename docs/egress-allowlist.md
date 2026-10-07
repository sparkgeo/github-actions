# Runner egress allowlist

Every job in `ci.yml` runs [`step-security/harden-runner`](https://github.com/step-security/harden-runner)
with `egress-policy: block`. Outbound connections from the runner succeed only
to the hosts listed for that job; everything else is dropped and reported in
the harden-runner post-step of the job log as `blocked`. This implements
SecOps plan Step 35 (runner egress control) and closes the audit phase of #28.

The lists below were derived from the `domain resolved:` lines in the
harden-runner post-step across four green runs on `main` (2026-10-07) and are
the source of truth. `ci.yml` must match this file; change both in one PR.

## Hosts allowed implicitly

The harden-runner agent ([`agent.go`](https://github.com/step-security/agent/blob/main/agent.go),
`addImplicitEndpoints`) always allows the GitHub Actions infrastructure, so these
are never listed per job:

| Host | Purpose |
|---|---|
| `*.actions.githubusercontent.com` | Actions runtime, action downloads, artefacts |
| `codeload.github.com` | action and release tarballs |
| `actions-results-receiver-production.githubapp.com`, `productionresultssa*.blob.core.windows.net` | job results and logs |
| GitHub meta-API `actions` domains | fetched at agent start |
| `agent.api.stepsecurity.io`, `prod.app-api.stepsecurity.io` | the agent itself (telemetry off when `disable-telemetry: true`) |

Action downloads happen at job setup, before the agent starts, and are not
subject to the policy.

## Per-job allowlist

All ports are 443.

| Job | Host | Needed by |
|---|---|---|
| Actionlint | `github.com`, `api.github.com` | checkout, reviewdog check annotations |
| | `ghcr.io`, `pkg-containers.githubusercontent.com` | reviewdog actionlint container image |
| TFLint | `github.com`, `release-assets.githubusercontent.com` | checksum-verified tflint binary and plugin releases |
| Kubeconform | `github.com`, `release-assets.githubusercontent.com` | checksum-verified kubeconform binary |
| Pre-commit | `github.com` | hook repositories |
| | `pypi.org`, `files.pythonhosted.org` | `pre-commit` install and Python hook environments |
| | `proxy.golang.org`, `sum.golang.org`, `storage.googleapis.com` | Go-based hooks (actionlint, zizmor hook environments) |
| Gitleaks | `github.com`, `release-assets.githubusercontent.com` | checksum-verified gitleaks binary |
| TruffleHog | `github.com`, `api.github.com`, `release-assets.githubusercontent.com` | checksum-verified trufflehog binary; verified-secret checks against GitHub |
| Zizmor | `github.com`, `api.github.com` | checkout, SARIF upload |
| | `ghcr.io`, `pkg-containers.githubusercontent.com` | zizmor container image |
| OpenSSF Scorecard | `github.com`, `api.github.com` | repository and branch-protection checks |
| | `api.deps.dev`, `api.osv.dev`, `www.bestpractices.dev`, `oss-fuzz-build-logs.storage.googleapis.com` | Scorecard checks (Vulnerabilities, Fuzzing, CII badge) |
| | `ghcr.io`, `pkg-containers.githubusercontent.com` | scorecard container image |
| Dependency Review | `github.com`, `api.github.com` | dependency graph comparison, PR comment |
| Terramate + OpenTofu Setup | `github.com`, `get.opentofu.org`, `release-assets.githubusercontent.com` | OpenTofu and Terramate installers |
| Storage Optimizer | `github.com` | checkout only |
| Threat Feeds | `github.com`, `api.github.com`, `release-assets.githubusercontent.com` | checkout; `gh release view` / `gh release download` of the mirror snapshot |

### Deliberately not allowed

| Host | Job | Why |
|---|---|---|
| `analytics.terramate.io` | Terramate + OpenTofu Setup | Terramate usage analytics; disabled with `TM_DISABLE_TELEMETRY=1` |
| `checkpoint-api.mineiros.io` | Terramate + OpenTofu Setup | HashiCorp-style version checkpoint used by Terramate and OpenTofu; disabled with `CHECKPOINT_DISABLE=1` and `TM_DISABLE_CHECKPOINT=1` |

### Pending jobs

| Job | Hosts | Tracked in |
|---|---|---|
| OSV-Scanner | `github.com`, `release-assets.githubusercontent.com` (binary), `api.osv.dev` (queries) | #54 |
| Severity Gate | none beyond checkout | #135 |

## Other workflows in this repo

| Workflow / job | Host | Needed by |
|---|---|---|
| Threat Feeds Mirror (`threat-feeds-mirror.yml`) | `www.cisa.gov` | CISA KEV catalogue |
| | `epss.empiricalsecurity.com` | FIRST EPSS scores (`epss.cyentia.com` redirects here; fetched directly) |
| | `threatfox.abuse.ch`, `feodotracker.abuse.ch`, `urlhaus.abuse.ch` | abuse.ch exports |
| | `github.com`, `api.github.com`, `uploads.github.com`, `release-assets.githubusercontent.com` | checkout, previous snapshot, release creation and asset upload, tracking issue |

The mirror is the only job in the organisation that may reach the upstream
feed hosts. Consuming workflows read the snapshot through the `threat-feeds`
composite and need only the three GitHub hosts listed for the Threat Feeds job.

## Reusable workflows

`lint-app.yml`, `lint-iac.yml`, `lint-helm.yml`, `lint-precommit.yml`,
`secrets-precommit.yml`, `secrets-scan.yml`, and `dep-scan-app.yml` run in the
calling repository's context and deliberately do not add `harden-runner`: the
consuming repo decides whether third-party CI telemetry is acceptable. A
consuming repo that wants block mode adds its own `harden-runner` step in the
calling job, using the hosts above for the composite it calls.

## Adding or changing a host

1. Run the job once with the new step; read the harden-runner post-step for
   `blocked` or new `domain resolved:` entries.
2. Add the host to the job's `allowed-endpoints` in `ci.yml` and to the table
   above with the step that needs it, in the same PR.
3. Prefer disabling a tool's telemetry over allowlisting its telemetry host.
4. Never allowlist a wildcard broader than the vendor's own domain.

## Self-hosted runners

Sparkgeo has no self-hosted runners today. If one is added:

- Ephemeral: one job per VM or container, destroyed afterwards.
- No workflow from a fork may run on it.
- No production credentials on the runner; cloud access via OIDC only.
- The StepSecurity agent (or the native GitHub egress firewall once GA) runs
  with the same per-job allowlists.
- Runner lives in an isolated account or project with no route to production.
