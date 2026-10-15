#!/usr/bin/env bash
# Annotate osv-scanner JSON results and enforce the gate (issue #5).
#
# Usage: gate.sh <osv.json> <critical|high|medium|low> <fail-on-malicious: true|false>
#
# One warning annotation per affected package with its advisory IDs and the
# highest CVSS score. Fails (exit 1) when any score is at or above the
# fail-on-severity threshold, or, with fail-on-malicious, when any advisory is
# an OpenSSF malicious-package report (MAL-*): those carry no CVSS score, so a
# severity threshold alone never blocks them (plan Step 3: osv-scanner picks up
# the malicious-packages feed through osv.dev). An empty max_severity is 0.
set -euo pipefail

JSON="$1" FAIL_ON="$2" FAIL_ON_MALICIOUS="${3:-true}"
case "${FAIL_ON}" in
  critical) THRESH=9.0 ;;
  high)     THRESH=7.0 ;;
  medium)   THRESH=4.0 ;;
  low)      THRESH=0.1 ;;
  *) echo "::error::invalid fail-on-severity '${FAIL_ON}'"; exit 1 ;;
esac

SCORES='[.groups[]?.max_severity | select(. != null and . != "") | tonumber]'

# Job-level annotations: lockfiles have no reliable source-line mapping.
jq -r ".results[]?.packages[]?
  | .package.name as \$p
  | (${SCORES} | max // 0) as \$s
  | ([.vulnerabilities[]?.id] | map(select(startswith(\"MAL-\")))) as \$mal
  | \"\(\$s)\t\(\$p)\t\([.vulnerabilities[]?.id] | join(\",\"))\t\(\$mal | join(\",\"))\"" "${JSON}" \
  | while IFS=$'\t' read -r sev pkg ids mal; do
      if [ -n "${mal}" ]; then
        echo "::error title=osv-scanner (malicious)::${pkg}: ${mal} is an OpenSSF malicious-package report; remove the package and rotate any secret the install could read (${ids})"
      else
        echo "::warning title=osv-scanner::${pkg}: ${ids} (max CVSS ${sev})"
      fi
    done

MAX="$(jq "[.results[]?.packages[]? | ${SCORES}[]] | max // 0" "${JSON}")"
MAL="$(jq '[.results[]?.packages[]?.vulnerabilities[]?.id | select(startswith("MAL-"))] | length' "${JSON}")"
echo "Highest CVSS severity found: ${MAX} (threshold ${THRESH} for '${FAIL_ON}'); malicious-package advisories: ${MAL}"
rc=0
if [ "${MAL}" -gt 0 ] && [ "${FAIL_ON_MALICIOUS}" = "true" ]; then
  echo "::error::${MAL} malicious-package advisory(ies) (MAL-*): blocking regardless of fail-on-severity."
  rc=1
fi
if awk "BEGIN{exit !(${MAX} >= ${THRESH})}"; then
  echo "::error::Dependency vulnerabilities at or above '${FAIL_ON}' severity (CVSS ${MAX})."
  rc=1
fi
exit "${rc}"
