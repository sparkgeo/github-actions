#!/usr/bin/env bash
# Checks the shared severity gate (format osv-json, issue #79) on recorded
# osv-scanner 2.4.0 JSON:
# flatmap-stream@0.1.1 (MAL-2025-20690, no CVSS score, plus two 9.8 GHSAs)
# and minimist@1.2.0 (GHSA scores 5.6 and 9.8). A MAL-* advisory blocks on
# its own; an empty max_severity is read as 0, not a jq error. Needs jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${HERE}/../../.github/actions/severity-gate/gate.sh"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
gate() {  # <name> <fixture> <severity> <fail-on-malicious>; sets rc
  set +e
  FINDINGS_FILE="${FIX}/$2" FORMAT=osv-json FAIL_ON="$3" FAIL_ON_MALICIOUS="$4" GITHUB_OUTPUT=/dev/null \
    bash "${GATE}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}

echo "== MAL-* only: no CVSS score, blocks at critical"
gate mal osv-mal-only.json critical true
[ "${rc}" -eq 1 ] || fail "mal rc ${rc}: $(cat "${TMP}/mal.log")"
grep -q '^::error title=severity-gate (malicious)::flatmap-stream: MAL-2025-20690 is an OpenSSF malicious-package report' "${TMP}/mal.log" || fail "malicious annotation: $(cat "${TMP}/mal.log")"
grep -q 'Highest CVSS severity found: 0 (none)' "${TMP}/mal.log" || fail "empty score is 0"
grep -q 'malicious-package advisories: 1$' "${TMP}/mal.log" || fail "mal count"

echo "== MAL-* only with fail-on-malicious false: reported, passes"
gate malok osv-mal-only.json critical false
[ "${rc}" -eq 0 ] || fail "malok rc ${rc}: $(cat "${TMP}/malok.log")"
grep -q '::error title=severity-gate (malicious)::flatmap-stream' "${TMP}/malok.log" || fail "still annotated"

echo "== CVE only: 9.8 blocks at critical; a medium-only scan below threshold passes"
gate cve osv-cve-only.json critical true
[ "${rc}" -eq 1 ] || fail "cve rc ${rc}"
grep -q '^::warning title=severity-gate::minimist: GHSA-vh95-rmgr-6w4m,GHSA-xvch-5gv4-984h (max CVSS 9.8)$' "${TMP}/cve.log" || fail "cve annotation: $(cat "${TMP}/cve.log")"
grep -q "^::error title=severity-gate::findings at or above 'critical' severity (CVSS 9.8)" "${TMP}/cve.log" || fail "cve gate"
jq '.results[].packages[].groups |= map(select(.max_severity == "5.6"))' "${FIX}/osv-cve-only.json" > "${TMP}/medium.json"
set +e; FINDINGS_FILE="${TMP}/medium.json" FORMAT=osv-json FAIL_ON=high GITHUB_OUTPUT=/dev/null bash "${GATE}" > "${TMP}/medium.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "5.6 below high must pass: $(cat "${TMP}/medium.log")"

echo "== both: one malicious error annotation, one warning, two gate errors"
gate both osv-mal-and-cve.json critical true
[ "${rc}" -eq 1 ] || fail "both rc ${rc}"
[ "$(grep -c '^::error title=severity-gate (malicious)::' "${TMP}/both.log")" = "1" ] || fail "one malicious package"
[ "$(grep -c '^::warning title=severity-gate::' "${TMP}/both.log")" = "1" ] || fail "one plain package"
[ "$(grep -c '^::error title=severity-gate::' "${TMP}/both.log")" = "2" ] || fail "both gates fire"

echo "== no results"
echo '{"results":[]}' > "${TMP}/empty.json"
set +e; FINDINGS_FILE="${TMP}/empty.json" FORMAT=osv-json FAIL_ON=critical GITHUB_OUTPUT=/dev/null bash "${GATE}" > "${TMP}/empty.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}"

echo "all osv-scanner gate checks passed"
