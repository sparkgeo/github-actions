#!/usr/bin/env bash
# Open or update the tracking issue for a scheduled DAST target (issue #68).
# One open issue per target host, titled "DAST scheduled scan: <host>". Its
# body lists the current High and Critical findings and keeps their keys in
# a hidden marker; a run that finds keys the marker lacks comments on the
# issue so the new findings notify watchers.
# Env: GH_TOKEN, REPO, TARGET, FINDINGS (report.py --out), RUN_URL.
set -euo pipefail
HOST="$(echo "${TARGET}" | sed -E 's#^https?://([^/:]+).*#\1#')"
TITLE="DAST scheduled scan: ${HOST}"
COUNT="$(jq length "${FINDINGS}")"

existing="$(TITLE="${TITLE}" gh issue list -R "${REPO}" --state open --label dast-scheduled --limit 100 --json number,title,body \
  --jq '[.[] | select(.title == env.TITLE)][0] // empty')"
if [ -z "${existing}" ] && [ "${COUNT}" = "0" ]; then
  echo "No High or Critical findings and no open tracking issue for ${HOST}."
  exit 0
fi

KEYS="$(jq -r '[.[].key] | unique | join(",")' "${FINDINGS}")"
BODY="$(jq -r --arg host "${HOST}" --arg run "${RUN_URL}" --arg keys "${KEYS}" '
  "Scheduled active DAST of **\($host)** (ZAP full scan, ZAP API scan, nuclei).\n\n" +
  (if length == 0 then "No High or Critical findings in the latest run.\n"
   else "| Severity | Tool | Finding | Where |\n|---|---|---|---|\n" +
        (map("| \(.severity) | \(.tool) | \(.name) | \(.where) |") | join("\n")) + "\n" end) +
  "\nLatest run: \($run)\n\nTriage each finding under the Step 25 SLA; close this issue when none remain.\n\n<!-- dast-keys: \($keys) -->"' "${FINDINGS}")"

if [ -z "${existing}" ]; then
  gh label create dast-scheduled -R "${REPO}" --color 0E8A16 --description "Scheduled DAST tracking issue" --force > /dev/null
  gh label create security-finding -R "${REPO}" --color 5319E7 --description "Security finding tracked under the Step 25 SLA" > /dev/null 2>&1 || true
  gh label create sla:high -R "${REPO}" --color D93F0B --description "Step 25 SLA: high" > /dev/null 2>&1 || true
  gh issue create -R "${REPO}" --title "${TITLE}" --label "dast-scheduled,security-finding,sla:high" --body "${BODY}"
  exit 0
fi

number="$(jq -r '.number' <<< "${existing}")"
old="$(jq -r '.body' <<< "${existing}" | sed -n 's/.*<!-- dast-keys: \(.*\) -->.*/\1/p' | tr ',' '\n')"
new="$(jq -r '.[].key' "${FINDINGS}" | sort -u | grep -vxF -f <(printf '%s\n' "${old}") || true)"
gh issue edit "${number}" -R "${REPO}" --body "${BODY}" > /dev/null
if [ -n "${new}" ]; then
  gh issue comment "${number}" -R "${REPO}" --body "New High or Critical findings in ${RUN_URL}:
$(printf '%s\n' "${new}" | sed 's/^/- /')"
fi
echo "Updated #${number} (${COUNT} High or Critical; new: $(printf '%s' "${new}" | grep -c . || true))."
