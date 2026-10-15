#!/usr/bin/env bash
# Open or update one issue per end-of-life product cycle (issue #230).
# Env: GH_TOKEN, REPO, REPORT (eol.py JSON), RUN_URL.
set -euo pipefail
gh label create end-of-life -R "${REPO}" --color B60205 --description "Runtime or framework past end of life (endoflife.date)" --force > /dev/null
for severity in high medium; do
  gh label create "sla:${severity}" -R "${REPO}" --color D93F0B --description "Step 25 SLA: ${severity}" > /dev/null 2>&1 || true
done
gh label create security-finding -R "${REPO}" --color 5319E7 --description "Security finding tracked under the Step 25 SLA" > /dev/null 2>&1 || true
# One issue per product cycle; a version string change within the cycle updates the same issue.
jq -c '[.[] | select(.status == "eol")] | group_by(.product + " " + .cycle)[] ' "${REPORT}" | while IFS= read -r group; do
  TITLE="$(jq -r '"End of life: \(.[0].product) \(.[0].cycle)"' <<< "${group}")"
  SEVERITY="$(jq -r '.[0].severity' <<< "${group}")"
  BODY="$(jq -r --arg run "${RUN_URL}" '
    "**\(.[0].product) \(.[0].cycle)** reached end of life on **\(.[0].eol)** and no longer receives security fixes. " +
    "The latest cycle is \(.[0].latest_cycle) (https://endoflife.date/\(.[0].product)).\n\n" +
    "Severity: \(.[0].severity) (SecOps plan Step 25; production runtimes are High).\n\n" +
    "Found in:\n" + (map("- `\(.source)`: \(.version)") | join("\n")) +
    "\n\nLast checked: \($run)\n\nClose this issue once every source above is on a supported cycle; the next run reopens a new one if not."' <<< "${group}")"
  existing="$(TITLE="${TITLE}" gh issue list -R "${REPO}" --state open --label end-of-life --limit 200 --json number,title \
    --jq '[.[] | select(.title == env.TITLE)][0].number // empty')"
  if [ -n "${existing}" ]; then
    gh issue edit "${existing}" -R "${REPO}" --body "${BODY}" > /dev/null
    echo "::notice title=eol-check::updated #${existing} (${TITLE})"
  else
    gh issue create -R "${REPO}" --title "${TITLE}" --label "security-finding,sla:${SEVERITY},end-of-life" --body "${BODY}"
  fi
done
