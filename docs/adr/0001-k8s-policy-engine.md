# ADR 0001: conftest (OPA/Rego) for the Kubernetes org-policy gate

**Status:** accepted · **Date:** 2026-10-07 · **Issue:** #77 (parent #60)

## Context

`trivy config` (#7) and `checkov` (#6) ship generic best-practice rules. Rules that are specific to Sparkgeo cannot be expressed in them: images only from ECR/GHCR/Chainguard, pinned image tags, mandatory resource requests and limits, non-root, no privileged containers, and later things like required labels or a NetworkPolicy per namespace. These need a policy engine that runs over the rendered manifests (`helm template` / `kustomize build`, the same rendering step `kubeconform` uses) in CI.

Two candidates were evaluated: [conftest](https://www.conftest.dev/) (OPA/Rego) and the [kyverno CLI](https://kyverno.io/docs/kyverno-cli/) (`kyverno apply`).

## Decision

Use conftest, with the starter policy bundle committed in this repo at `.github/actions/k8s-policy/policies/` and consumed through the `k8s-policy` composite / `k8s-policy.yml` reusable workflow.

## Rationale

| | conftest | kyverno CLI |
|---|---|---|
| Policy language | Rego: general purpose, unit-testable (`conftest verify`), reusable for Terraform, Dockerfiles, CI YAML, SBOMs | Kyverno YAML: Kubernetes-only, JMESPath/CEL; pattern matching for simple rules, awkward for anything derived (registry parsing, "pod or container" overrides) |
| Scope of the same policy set | Kubernetes now; the same engine can gate IaC and workflow files later with one skill set | Kubernetes only |
| Binary | Single static binary, ~45 MB, checksums published with the release | Single binary, ~100 MB, needs a cluster-shaped `ResourcePolicy` context for some rules |
| Structured output | `json`, `sarif`, `junit`, `github` | `json`/`yaml` report; GitHub annotations hand-rolled |
| External data | `--data` YAML/JSON merged into `data` (per-repo overrides without forking policies) | Variables via `--set`, no structured data document |
| In-cluster reuse | Same Rego runs in Gatekeeper (with a thin ConstraintTemplate wrapper) | Same YAML runs in the Kyverno admission controller unchanged |
| Rendered Helm/Kustomize input | Native: multi-document YAML, one `input` per document | Native |
| Team familiarity | Rego is new to most of the team; this repo already evaluates OPA-style policy in `trivy`'s built-in checks | Kyverno YAML is approachable for anyone who writes Kubernetes YAML |

kyverno's advantage is a zero-translation path to in-cluster admission control. That is not on the roadmap: no Sparkgeo cluster runs Kyverno or Gatekeeper today, and the CI gate is the enforcement point this plan calls for. conftest's advantages are structural: one policy language and one binary that can cover Kubernetes, IaC and CI config, unit-testable rules, and a data overlay for per-repo exceptions. Rego's learning curve is mitigated by keeping the bundle small, commenting every rule, and testing it against fixture manifests in CI (`tests/k8s-policy/run.sh`).

## Consequences

- Org policy lives in this repo and is versioned with it; a consumer pinned to a SHA gets a fixed policy set. New rules ship as a new SHA, not as a silent change.
- Per-repo overrides go through `data-path` (allowed registries) and `policy-path` (additional rules), never by editing the bundle in a fork.
- If in-cluster enforcement is adopted later, the Rego bundle moves to its own repo (`sparkgeo/k8s-policies`) and is wrapped in Gatekeeper ConstraintTemplates; the CI gate switches `actions-ref` for a policy ref at that point.
- SARIF upload is intentionally omitted. Policy denies are hard gate failures, not findings to triage in the Security tab; conftest can emit `-o sarif` if that changes.
