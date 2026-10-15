#!/usr/bin/env bash
# Checks the osv-scanner gate (gate.sh) on recorded osv-scanner 2.4.0 JSON:
# flatmap-stream@0.1.1 (MAL-2025-20690, no CVSS score, plus two 9.8 GHSAs)
# and minimist@1.2.0 (GHSA scores 5.6 and 9.8). A MAL-* advisory blocks on
# its own; an empty max_severity is read as 0, not a jq error. Needs jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../../.github/actions/osv-scanner/gate.sh"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
gate() {  # <name> <fixture> <severity> <fail-on-malicious>; sets rc
  set +e
  bash "${GATE}" "${FIX}/$2" "$3" "$4" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}

echo "== MAL-* only: no CVSS score, blocks at critical"
gate mal osv-mal-only.json critical true
[ "${rc}" -eq 1 ] || fail "mal rc ${rc}: $(cat "${TMP}/mal.log")"
grep -q '^::error title=osv-scanner (malicious)::flatmap-stream: MAL-2025-20690 is an OpenSSF malicious-package report' "${TMP}/mal.log" || fail "malicious annotation: $(cat "${TMP}/mal.log")"
grep -q 'Highest CVSS severity found: 0 ' "${TMP}/mal.log" || fail "empty score is 0"
grep -q 'malicious-package advisories: 1$' "${TMP}/mal.log" || fail "mal count"

echo "== MAL-* only with fail-on-malicious false: reported, passes"
gate malok osv-mal-only.json critical false
[ "${rc}" -eq 0 ] || fail "malok rc ${rc}: $(cat "${TMP}/malok.log")"
grep -q '::error title=osv-scanner (malicious)::flatmap-stream' "${TMP}/malok.log" || fail "still annotated"

echo "== CVE only: 9.8 blocks at critical; a medium-only scan below threshold passes"
gate cve osv-cve-only.json critical true
[ "${rc}" -eq 1 ] || fail "cve rc ${rc}"
grep -q '^::warning title=osv-scanner::minimist: GHSA-vh95-rmgr-6w4m,GHSA-xvch-5gv4-984h (max CVSS 9.8)$' "${TMP}/cve.log" || fail "cve annotation: $(cat "${TMP}/cve.log")"
grep -q "^::error::Dependency vulnerabilities at or above 'critical' severity (CVSS 9.8)" "${TMP}/cve.log" || fail "cve gate"
jq '.results[].packages[].groups |= map(select(.max_severity == "5.6"))' "${FIX}/osv-cve-only.json" > "${TMP}/medium.json"
set +e; bash "${GATE}" "${TMP}/medium.json" high true > "${TMP}/medium.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "5.6 below high must pass: $(cat "${TMP}/medium.log")"

echo "== both: one malicious error annotation, one warning, two gate errors"
gate both osv-mal-and-cve.json critical true
[ "${rc}" -eq 1 ] || fail "both rc ${rc}"
[ "$(grep -c '^::error title=osv-scanner (malicious)::' "${TMP}/both.log")" = "1" ] || fail "one malicious package"
[ "$(grep -c '^::warning title=osv-scanner::' "${TMP}/both.log")" = "1" ] || fail "one plain package"
[ "$(grep -c '^::error::' "${TMP}/both.log")" = "2" ] || fail "both gates fire"

echo "== no results"
echo '{"results":[]}' > "${TMP}/empty.json"
set +e; bash "${GATE}" "${TMP}/empty.json" critical true > "${TMP}/empty.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}"

echo "all osv-scanner gate checks passed"
