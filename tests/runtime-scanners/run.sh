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
