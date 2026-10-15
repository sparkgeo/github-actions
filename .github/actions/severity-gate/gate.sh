#!/usr/bin/env bash
# Shared severity gate. Inputs via env: FINDINGS_FILE, FORMAT, FAIL_ON, and
# FAIL_ON_MALICIOUS (default true). Writes max-score, max-severity and
# malicious-count to GITHUB_OUTPUT. See docs/gate-policy.md.
#
# osv-json: an OpenSSF malicious-package advisory (MAL-*) carries no CVSS
# score, so a severity threshold alone never blocks it; with
# FAIL_ON_MALICIOUS it blocks regardless of FAIL_ON (issue #5). An empty
# max_severity, which osv-scanner 2.4.0 writes for MAL-* groups, reads as 0.
set -euo pipefail
case "${FAIL_ON}" in
  critical) THRESH=9.0 ;;
  high)     THRESH=7.0 ;;
  medium|moderate) THRESH=4.0 ;;
  low)      THRESH=0.1 ;;
  none)     THRESH="" ;;
  *) echo "::error title=severity-gate::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

FAIL_ON_MALICIOUS="${FAIL_ON_MALICIOUS:-true}"

# Each format yields lines of "<max score>\t<package>\t<ids>\t<malicious ids>".
case "${FORMAT}" in
  osv-json)
    ROWS="$(jq -r '.results[]?.packages[]?
      | .package.name as $p
      | ([.groups[]?.max_severity | select(. != null and . != "") | tonumber] | max // 0) as $s
      | ([.vulnerabilities[]?.id] | map(select(startswith("MAL-")))) as $mal
      | "\($s)\t\($p)\t" + ([.vulnerabilities[]?.id] | join(",")) + "\t" + ($mal | join(","))' "${FINDINGS_FILE}")" ;;
  *) echo "::error title=severity-gate::unknown findings format '${FORMAT}'"; exit 1 ;;
esac

MAX=0
MAL=0
while IFS=$'\t' read -r sev pkg ids mal; do
  [ -n "${pkg:-}" ] || continue
  if [ -n "${mal:-}" ]; then
    MAL=$((MAL + $(tr ',' '\n' <<< "${mal}" | wc -l)))
    echo "::error title=severity-gate (malicious)::${pkg}: ${mal} is an OpenSSF malicious-package report; remove the package and rotate any secret the install could read (${ids})"
  else
    echo "::warning title=severity-gate::${pkg}: ${ids} (max CVSS ${sev})"
  fi
  if awk "BEGIN{exit !(${sev} > ${MAX})}"; then MAX="${sev}"; fi
done <<< "${ROWS}"

if   awk "BEGIN{exit !(${MAX} >= 9.0)}"; then MAXSEV=critical
elif awk "BEGIN{exit !(${MAX} >= 7.0)}"; then MAXSEV=high
elif awk "BEGIN{exit !(${MAX} >= 4.0)}"; then MAXSEV=medium
elif awk "BEGIN{exit !(${MAX} >= 0.1)}"; then MAXSEV=low
else MAXSEV=none; fi
{
  echo "max-score=${MAX}"
  echo "max-severity=${MAXSEV}"
  echo "malicious-count=${MAL}"
} >> "${GITHUB_OUTPUT}"
echo "Highest CVSS severity found: ${MAX} (${MAXSEV}); threshold '${FAIL_ON}'; malicious-package advisories: ${MAL}"

rc=0
if [ "${MAL}" -gt 0 ] && [ "${FAIL_ON_MALICIOUS}" = "true" ]; then
  echo "::error title=severity-gate::${MAL} malicious-package advisory(ies) (MAL-*): blocking regardless of fail-on-severity."
  rc=1
fi
if [ -n "${THRESH}" ] && awk "BEGIN{exit !(${MAX} >= ${THRESH})}"; then
  echo "::error title=severity-gate::findings at or above '${FAIL_ON}' severity (CVSS ${MAX})."
  rc=1
fi
exit "${rc}"
