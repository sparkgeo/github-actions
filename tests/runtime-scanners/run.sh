#!/usr/bin/env bash
# Checks for the runtime-relevance exporter and SARIF annotator (issue #179).
# The exporter runs on recorded Kubescape and Trivy Operator objects
# (fixtures/collected, captured from the kind CI job); the annotator on a
# fixture export and SARIF.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="${HERE}/../../.github/actions/runtime-relevance"
F="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
r() { jq -r --arg id "$1" ".runs[0].results[] | select(.ruleId == \$id) | $2" "${TMP}/$3.sarif"; }

echo "== export: recorded Kubescape 1.40 and Trivy Operator 0.36 objects"
python3 -I "${A}/export.py" --input "${F}/collected" --output "${TMP}/export.json" --cluster fixture --now 2026-10-15T22:00:00Z > /dev/null
e() { jq -r --arg w "$1" --arg p "$2" '.entries[] | select(.workload == $w and .package == $p) | .relevant' "${TMP}/export.json"; }
[ "$(e demo/Deployment/web libssl1.1)" = "true" ] || fail "loaded libssl1.1"
[ "$(e demo/Deployment/web libwebp6)" = "false" ] || fail "libwebp6 not loaded"
[ "$(e demo/Deployment/web perl-base)" = "false" ] || fail "perl-base not loaded"
[ "$(e demo/deployment/worker libssl1.1)" = "unknown" ] || fail "workload without filtered manifest"
[ "$(jq '[.entries[] | select(.workload == "demo/deployment/web")] | length' "${TMP}/export.json")" = "0" ] \
  || fail "summary duplicated a workload that has a filtered manifest"
[ "$(jq -r '.entries[] | select(.workload == "batch/ReplicaSet/batch-5d4f") | .source' "${TMP}/export.json" | sort -u)" = "trivy-operator" ] \
  || fail "trivy-only image"
[ "$(jq '[.entries[] | select(.source == "trivy-operator" and (.image | startswith("sha256:b997")))] | length' "${TMP}/export.json")" = "0" ] \
  || fail "trivy duplicated an image Kubescape covers"
[ "$(jq -r '.entries[] | select(.package == "libwebp6" and .workload == "demo/Deployment/web") | .image' "${TMP}/export.json")" = \
  "sha256:b997b0db9c2bc0a2fb803ced5fb9ff3a757e54903a28ada3e50412cc3ab7822f" ] || fail "image digest"
[ "$(jq -c .counts "${TMP}/export.json")" = '{"entries":15,"true":3,"false":3,"unknown":9}' ] || fail "counts $(jq -c .counts "${TMP}/export.json")"

echo "== export feeds the EPSS/KEV override's runtime-relevance-file format"
[ "$(jq '[.entries[] | select(.relevant == false) | has("package") and has("cve")] | all' "${TMP}/export.json")" = "true" ] || fail "fields"

echo "== annotate: any image"
GITHUB_OUTPUT="${TMP}/out" python3 -I "${A}/annotate.py" --sarif "${F}/scan.sarif" --export "${F}/export.json" --output "${TMP}/any.sarif" > /dev/null
[ "$(r CVE-2023-0001 '.properties["runtime-relevant"]' any)" = "true" ] || fail "loaded package"
[ "$(r CVE-2023-0002 '.properties["runtime-relevant"]' any)" = "false" ] || fail "not-loaded package"
[ "$(r CVE-2023-0002 '.properties.tags | join(",")' any)" = "runtime:not-loaded" ] || fail "not-loaded tag"
[ "$(r CVE-2023-0003 '.properties["runtime-relevant"]' any)" = "true" ] || fail "loaded in one workload must win"
[ "$(r CVE-2023-0004 '.properties["runtime-relevant"]' any)" = "unknown" ] || fail "unknown"
[ "$(r CVE-2023-9999 '.properties // {} | has("runtime-relevant")' any)" = "false" ] || fail "CVE absent from export annotated"
[ "$(r CVE-2023-0002-libxml2 '.properties["runtime-relevant"]' any)" = "false" ] || fail "grype-style rule id"
[ "$(r CVE-2023-0002-libxml2 '.properties.tags | join(",")' any)" = "runtime:not-loaded,security" ] || fail "existing tags kept"
[ "$(r DS002 '.properties // {} | has("runtime-relevant")' any)" = "false" ] || fail "non-CVE annotated"
grep -qx 'not-loaded=2' "${TMP}/out" || fail "not-loaded output: $(cat "${TMP}/out")"

echo "== annotate: one image"
python3 -I "${A}/annotate.py" --sarif "${F}/scan.sarif" --export "${F}/export.json" --output "${TMP}/one.sarif" --image sha256:aaaa > /dev/null
[ "$(r CVE-2023-0003 '.properties["runtime-relevant"]' one)" = "false" ] || fail "image filter"
[ "$(r CVE-2023-0004 '.properties // {} | has("runtime-relevant")' one)" = "false" ] || fail "other image leaked"

echo "all runtime-relevance checks passed"
