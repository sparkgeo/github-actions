#!/usr/bin/env bash
# Checks sbom.sh (the script behind .github/actions/syft) against a fixture
# directory. Needs syft on PATH or in $SYFT, plus jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOM="${HERE}/../../.github/actions/syft/sbom.sh"
SYFT="${SYFT:-syft}"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_sbom() {  # <target> <formats> <output-dir>
  rm -f "${TMP}/out" "${TMP}/summary"
  touch "${TMP}/out" "${TMP}/summary"
  set +e
  SYFT="${SYFT}" TARGET="$1" FORMATS="$2" OUTPUT_DIR="$3" \
    GITHUB_OUTPUT="${TMP}/out" GITHUB_STEP_SUMMARY="${TMP}/summary" \
    bash "${SBOM}" > "${TMP}/log" 2>&1
  rc=$?
  set -e
}

echo "== both formats from a directory"
run_sbom "${FIX}/app" "cyclonedx-json,spdx-json" "${TMP}/sbom"
[ "${rc}" -eq 0 ] || { cat "${TMP}/log"; fail "expected rc 0, got ${rc}"; }
[ -f "${TMP}/sbom/sbom.cyclonedx.json" ] || fail "missing sbom.cyclonedx.json"
[ -f "${TMP}/sbom/sbom.spdx.json" ] || fail "missing sbom.spdx.json"
[ "$(jq '[.components[] | select(.type != "file")] | length' "${TMP}/sbom/sbom.cyclonedx.json")" -eq 2 ] || fail "cyclonedx: expected 2 components"
jq -e '.components[] | select(.name == "requests" and .version == "2.34.2")' "${TMP}/sbom/sbom.cyclonedx.json" > /dev/null || fail "cyclonedx: requests 2.34.2 missing"
[ "$(jq '[.packages[] | select(.SPDXID | startswith("SPDXRef-Package-"))] | length' "${TMP}/sbom/sbom.spdx.json")" -eq 2 ] || fail "spdx: expected 2 packages"
grep -q "^sbom-dir=${TMP}/sbom$" "${TMP}/out" || fail "sbom-dir output"
grep -q "^files=sbom.cyclonedx.json,sbom.spdx.json$" "${TMP}/out" || fail "files output"
grep -q '| sbom.cyclonedx.json | 2 |' "${TMP}/summary" || fail "summary row for cyclonedx"
grep -q '| sbom.spdx.json | 2 |' "${TMP}/summary" || fail "summary row for spdx"

echo "== single format"
run_sbom "${FIX}/app" "spdx-json" "${TMP}/one"
[ "${rc}" -eq 0 ] || fail "single: expected rc 0, got ${rc}"
[ -f "${TMP}/one/sbom.spdx.json" ] || fail "single: missing sbom.spdx.json"
[ ! -e "${TMP}/one/sbom.cyclonedx.json" ] || fail "single: cyclonedx written unexpectedly"
grep -q '^files=sbom.spdx.json$' "${TMP}/out" || fail "single: files output"

echo "== unknown format rejected"
run_sbom "${FIX}/app" "cyclonedx-json,syft-table" "${TMP}/bad"
[ "${rc}" -eq 1 ] || fail "unknown format: expected rc 1, got ${rc}"
grep -q '::error.*syft-table' "${TMP}/log" || fail "unknown format: missing error annotation"
[ ! -e "${TMP}/bad/sbom.cyclonedx.json" ] || fail "unknown format: wrote output before validating"

echo "PASS"
