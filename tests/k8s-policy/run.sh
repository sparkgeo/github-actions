#!/usr/bin/env bash
# Checks the bundled Rego policies and gate.sh against recorded fixtures.
# Needs conftest on PATH or in $CONFTEST, plus jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${HERE}/../../.github/actions/k8s-policy"
POLICIES="${ACTION}/policies"
GATE="${ACTION}/gate.sh"
CONFTEST="${CONFTEST:-conftest}"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_gate() {  # <results> <fail-on-warn>
  rm -f "${TMP}/out" "${TMP}/summary"
  touch "${TMP}/out" "${TMP}/summary"
  set +e
  RESULTS="$1" RENDER_DIR=rendered FAIL_ON_WARN="$2" \
    GITHUB_OUTPUT="${TMP}/out" GITHUB_STEP_SUMMARY="${TMP}/summary" \
    bash "${GATE}" > "${TMP}/log" 2>&1
  rc=$?
  set -e
}

# --- Policies: evaluate fixture manifests and assert on the exact set of messages
policy_msgs() {  # <manifest> [extra conftest args]
  local m="$1"; shift
  "${CONFTEST}" test --all-namespaces -p "${POLICIES}" -o json --no-fail "$@" "${m}" \
    | jq -r '.[] | .failures[]? | .msg' | sort
}

echo "== policies: insecure manifest denies"
policy_msgs "${FIX}/manifests/insecure.yaml" > "${TMP}/msgs"
cat > "${TMP}/want" <<'WANT'
CronJob/nightly container job: must run as non-root (securityContext.runAsNonRoot: true on the pod or the container)
CronJob/nightly container job: must set resources.requests.cpu, resources.requests.memory, resources.limits.memory (missing: requests.cpu, requests.memory, limits.memory)
Deployment/web container app: image "nginx:latest" is not from an allowed registry (ghcr.io, cgr.dev, public.ecr.aws, *.dkr.ecr.*.amazonaws.com)
Deployment/web container app: image "nginx:latest" uses the latest tag or no tag; pin a tag or digest
Deployment/web container app: must run as non-root (securityContext.runAsNonRoot: true on the pod or the container)
Deployment/web container app: must set resources.requests.cpu, resources.requests.memory, resources.limits.memory (missing: requests.cpu, requests.memory, limits.memory)
Deployment/web container app: securityContext.privileged must not be true
Deployment/web container init: image "busybox" is not from an allowed registry (ghcr.io, cgr.dev, public.ecr.aws, *.dkr.ecr.*.amazonaws.com)
Deployment/web container init: image "busybox" uses the latest tag or no tag; pin a tag or digest
Deployment/web container init: must not run as root (securityContext.runAsUser: 0)
Deployment/web container init: must set resources.requests.cpu, resources.requests.memory, resources.limits.memory (missing: requests.cpu, requests.memory, limits.memory)
WANT
diff -u "${TMP}/want" "${TMP}/msgs" || fail "insecure manifest: unexpected deny set"

echo "== policies: clean manifest passes"
policy_msgs "${FIX}/manifests/clean.yaml" > "${TMP}/msgs"
[ ! -s "${TMP}/msgs" ] || fail "clean manifest produced denies: $(cat "${TMP}/msgs")"

echo "== policies: data override restricts registries"
policy_msgs "${FIX}/manifests/clean.yaml" -d "${FIX}/data" > "${TMP}/msgs"
cat > "${TMP}/want" <<'WANT'
Deployment/web container app: image "123456789012.dkr.ecr.us-west-2.amazonaws.com/web:1.4.2" is not from an allowed registry (ghcr.io)
Deployment/web container sidecar: image "cgr.dev/chainguard/static@sha256:fe55470f6bdd0c5e1a2e9b9f4c6a7f6c0a2a5c0a4f2b2e6a5d6d7c9a2b4c6e8f" is not from an allowed registry (ghcr.io)
WANT
diff -u "${TMP}/want" "${TMP}/msgs" || fail "data override: unexpected deny set"

# --- gate.sh: annotations, summary, outputs, exit code
echo "== gate: denies block"
run_gate "${FIX}/results/deny.json" false
[ "${rc}" -eq 1 ] || fail "deny: expected rc 1, got ${rc}"
[ "$(grep -c '^::error title=k8s-policy charts/web::' "${TMP}/log")" -eq 3 ] || fail "deny: expected 3 error annotations for charts/web"
grep -q '^::warning title=k8s-policy charts/web::Deployment/web: no app.kubernetes.io/name label$' "${TMP}/log" || fail "deny: missing warning annotation"
grep -q '^deny-count=3$' "${TMP}/out" || fail "deny: deny-count output"
grep -q '^warn-count=1$' "${TMP}/out" || fail "deny: warn-count output"
grep -q '| charts/web | deny | Deployment/web container app: securityContext.privileged must not be true |' "${TMP}/summary" || fail "deny: summary row"
grep -q 'kustomize/overlays/dev' "${TMP}/summary" || fail "deny: summary should list the passing target"

echo "== gate: clean passes, warnings do not block"
run_gate "${FIX}/results/clean.json" false
[ "${rc}" -eq 0 ] || fail "clean: expected rc 0, got ${rc}"
[ "$(grep -c '^::error' "${TMP}/log")" -eq 0 ] || fail "clean: unexpected error annotation"
grep -q '^deny-count=0$' "${TMP}/out" || fail "clean: deny-count output"

echo "== gate: fail-on-warn blocks on warnings"
run_gate "${FIX}/results/clean.json" true
[ "${rc}" -eq 1 ] || fail "fail-on-warn: expected rc 1, got ${rc}"

echo "== gate: missing results file fails"
run_gate "${TMP}/nope.json" false
[ "${rc}" -ne 0 ] || fail "missing results: expected non-zero rc"

echo "all k8s-policy checks passed"
