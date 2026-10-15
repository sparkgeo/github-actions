#!/usr/bin/env bash
# Re-imports one findings file into DefectDojo (issue #185). Inputs via env:
# DD_URL, DD_TOKEN (both empty: skip), FILE, SCAN_TYPE, PRODUCT,
# PRODUCT_TYPE, ENGAGEMENT, ENVIRONMENT, TAGS (comma-separated),
# MIN_SEVERITY, CLOSE_OLD, PUSH_JIRA. Writes imported, test-id, created,
# closed, reactivated and untouched to GITHUB_OUTPUT.
#
# reimport-scan with auto_create_context creates the product, engagement and
# test on first use and deduplicates against the same test afterwards; with
# close_old_findings a finding missing from this file is closed (the Fix
# outcome), and do_not_reactivate keeps a risk-accepted finding accepted.
set -euo pipefail

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

if [ -z "${DD_URL:-}" ] || [ -z "${DD_TOKEN:-}" ]; then
  echo "DefectDojo not configured (DEFECTDOJO_URL / DEFECTDOJO_TOKEN unset); import skipped"
  echo "DefectDojo import skipped: DEFECTDOJO_URL and DEFECTDOJO_TOKEN are not set." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  out imported false
  exit 0
fi
if [[ ! "${DD_URL}" =~ ^https:// && ! "${DD_URL}" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
  echo "::error title=defectdojo-import::DEFECTDOJO_URL must be https (http only for localhost)"
  exit 1
fi
[ -s "${FILE}" ] || { echo "::error title=defectdojo-import::findings file '${FILE}' is missing or empty"; exit 1; }

case "${ENVIRONMENT}" in  # DefectDojo's default environment names
  production) env_name=Production ;;
  staging) env_name=Staging ;;
  development) env_name=Development ;;
  test) env_name=Test ;;
  *) echo "::error title=defectdojo-import::environment must be production, staging, development or test"; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# The token goes in a header file, not on curl's command line.
printf 'Authorization: Token %s\n' "${DD_TOKEN}" > "${TMP}/auth"
chmod 600 "${TMP}/auth"

form=(
  -F "scan_type=${SCAN_TYPE}" -F "file=@${FILE}"
  -F "product_name=${PRODUCT}" -F "product_type_name=${PRODUCT_TYPE}" -F "engagement_name=${ENGAGEMENT}"
  -F "auto_create_context=true" -F "environment=${env_name}"
  -F "close_old_findings=${CLOSE_OLD}" -F "do_not_reactivate=true"
  -F "minimum_severity=${MIN_SEVERITY}" -F "push_to_jira=${PUSH_JIRA}"
  -F "active=true" -F "verified=false" -F "apply_tags_to_findings=true"
  # Respond once deduplication has run, so the counts below are final.
  -F "deduplication_execution_mode=async_wait"
)
IFS=',' read -ra tags <<< "${TAGS:-}"
for t in "${tags[@]}" "env:${ENVIRONMENT}"; do
  t="$(echo "${t}" | xargs)"
  [ -z "${t}" ] || form+=(-F "tags=${t}")
done

code="$(curl -sS -o "${TMP}/resp.json" -w '%{http_code}' -X POST -H @"${TMP}/auth" "${form[@]}" \
  "${DD_URL%/}/api/v2/reimport-scan/")"
if [ "${code}" -lt 200 ] || [ "${code}" -ge 300 ]; then
  echo "::error title=defectdojo-import::reimport-scan returned HTTP ${code}: $(head -c 500 "${TMP}/resp.json")"
  exit 1
fi

# Re-import into an existing test returns statistics.delta.<action>.total.total;
# the first import (new test) returns only statistics.after, all of it new.
read -r test_id created closed reactivated untouched < <(jq -r '
  def n(k): .statistics.delta[k].total.total // 0;
  if .statistics.delta then [.test, n("created"), n("closed"), n("reactivated"), n("untouched")]
  else [.test, (.statistics.after.total.total // 0), 0, 0, 0] end | @tsv' "${TMP}/resp.json")
out imported true
out test-id "${test_id}"
out created "${created}"
out closed "${closed}"
out reactivated "${reactivated}"
out untouched "${untouched}"
{
  echo "### DefectDojo import"
  echo
  echo "| Product | Engagement | Scan type | Test | New | Closed | Reactivated | Unchanged |"
  echo "|---|---|---|---|---|---|---|---|"
  echo "| ${PRODUCT} | ${ENGAGEMENT} (${env_name}) | ${SCAN_TYPE} | ${test_id} | ${created} | ${closed} | ${reactivated} | ${untouched} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "DefectDojo test ${test_id}: ${created} new, ${closed} closed, ${reactivated} reactivated, ${untouched} unchanged"
