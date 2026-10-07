#!/usr/bin/env bash
# Shared severity gate. Inputs via env: FINDINGS_FILE, FORMAT, FAIL_ON.
# Writes max-score and max-severity to GITHUB_OUTPUT. See docs/gate-policy.md.
set -euo pipefail
case "${FAIL_ON}" in
  critical) THRESH=9.0 ;;
  high)     THRESH=7.0 ;;
  medium|moderate) THRESH=4.0 ;;
  low)      THRESH=0.1 ;;
  none)     THRESH="" ;;
  *) echo "::error title=severity-gate::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

# Each format yields lines of "<max score>\t<package>\t<ids>".
case "${FORMAT}" in
  osv-json)
    ROWS="$(jq -r '.results[]?.packages[]?
      | .package.name as $p
      | ([.groups[]?.max_severity | select(. != null) | tonumber] | max // 0) as $s
      | "\($s)\t\($p)\t" + ([.vulnerabilities[]?.id] | join(","))' "${FINDINGS_FILE}")" ;;
  *) echo "::error title=severity-gate::unknown findings format '${FORMAT}'"; exit 1 ;;
esac

MAX=0
while IFS=$'\t' read -r sev pkg ids; do
  [ -n "${pkg:-}" ] || continue
  echo "::warning title=severity-gate::${pkg}: ${ids} (max CVSS ${sev})"
  if awk "BEGIN{exit !(${sev} > ${MAX})}"; then MAX="${sev}"; fi
done <<< "${ROWS}"

if   awk "BEGIN{exit !(${MAX} >= 9.0)}"; then MAXSEV=critical
elif awk "BEGIN{exit !(${MAX} >= 7.0)}"; then MAXSEV=high
elif awk "BEGIN{exit !(${MAX} >= 4.0)}"; then MAXSEV=medium
elif awk "BEGIN{exit !(${MAX} >= 0.1)}"; then MAXSEV=low
else MAXSEV=none; fi
echo "max-score=${MAX}" >> "${GITHUB_OUTPUT}"
echo "max-severity=${MAXSEV}" >> "${GITHUB_OUTPUT}"
echo "Highest CVSS severity found: ${MAX} (${MAXSEV}); threshold '${FAIL_ON}'"

if [ -n "${THRESH}" ] && awk "BEGIN{exit !(${MAX} >= ${THRESH})}"; then
  echo "::error title=severity-gate::findings at or above '${FAIL_ON}' severity (CVSS ${MAX})."
  exit 1
fi
