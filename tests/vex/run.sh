#!/usr/bin/env bash
# VEX (issue #232). Fixture: an SBOM with certifi 2022.12.7, which grype
# matches to two advisories: GHSA-xqr8-7jwr-rhp7 (CVE-2023-37920, High) and
# GHSA-248v-346w-9cwc (CVE-2024-39689, Low). One reviewed statement marks the
# High one not_affected. Checks vex.py (schema, staleness, CycloneDX copy)
# and the grype gate against results recorded with and without the merged
# VEX (grype 0.120.1, 2026-10-15): at fail-on high the gate passes only with
# the VEX applied. Needs jq and python3.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VEXPY="${HERE}/../../.github/actions/vex/vex.py"
GATE="${HERE}/../../.github/actions/grype/gate.sh"
FIX="${HERE}/fixtures"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
vexpy() { python3 -I "${VEXPY}" --statements "$1" --sbom "${FIX}/sbom.cyclonedx.json" --cyclonedx "${WORK}/cdx.json" 2> "${WORK}/stderr"; }

status=0; vexpy "${FIX}/vex" > "${WORK}/out" || status=$?
check "fixture statement passes and is in the SBOM" "$(tr '\n' ' ' < "${WORK}/out")${status}" "statement-count=1 stale-count=0 0"
check "CycloneDX copy points at the SBOM bom-ref" \
  "$(jq -r '.vulnerabilities[0] | "\(.id) \(.analysis.state) \(.analysis.justification) \(.affects[0].ref)"' "${WORK}/cdx.json")" \
  "CVE-2023-37920 not_affected protected_by_mitigating_control pkg:pypi/certifi@2022.12.7?package-id=fixture"

mkdir -p "${WORK}/bad" "${WORK}/stale"
jq 'del(.statements[0].justification)' "${FIX}/vex/CVE-2023-37920.json" > "${WORK}/bad/x.json"
status=0; vexpy "${WORK}/bad" > /dev/null || status=$?
check "not_affected without a justification is rejected" "$(grep -c 'not_affected needs a justification' "${WORK}/stderr")/${status}" "1/1"
jq '.statements[0].products[0]["@id"] = "pkg:pypi/certifi@2023.7.22"' "${FIX}/vex/CVE-2023-37920.json" > "${WORK}/stale/x.json"
status=0; vexpy "${WORK}/stale" > "${WORK}/out" || status=$?
check "statement for a package not in the SBOM is stale" "$(grep stale-count "${WORK}/out")/${status}" "stale-count=1/0"

gate() { RESULTS="$1" FAIL_ON_SEVERITY=high VEX="${2:-}" GITHUB_OUTPUT="${WORK}/gate" GITHUB_STEP_SUMMARY=/dev/null bash "${GATE}" > "${WORK}/log" 2>&1; }
: > "${WORK}/gate"; status=0; gate "${FIX}/results/without-vex.json" || status=$?
check "without VEX the High match blocks" "$(grep blocking "${WORK}/gate")/${status}" "blocking-count=1/1"
: > "${WORK}/gate"; status=0; gate "${FIX}/results/with-vex.json" "${FIX}/vex/CVE-2023-37920.json" || status=$?
check "with VEX the gate passes and lists the suppressed match" \
  "$(grep -E 'blocking|suppressed|stale' "${WORK}/gate" | tr '\n' ' ')/$(grep -c 'not affected per VEX' "${WORK}/log")/${status}" \
  "blocking-count=0 vex-suppressed-count=1 vex-stale-count=0 /1/0"
jq '.statements[0].vulnerability = {"name": "CVE-2099-0001"}' "${FIX}/vex/CVE-2023-37920.json" > "${WORK}/stale.json"
: > "${WORK}/gate"; status=0; gate "${FIX}/results/with-vex.json" "${WORK}/stale.json" || status=$?
check "a statement grype no longer reports is stale" "$(grep stale "${WORK}/gate")" "vex-stale-count=1"

exit "${fail}"
