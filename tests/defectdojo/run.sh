#!/usr/bin/env bash
# DefectDojo hand-off checks (issue #185).
#   run.sh skip         import.sh with no URL/token: skipped, imported=false
#   run.sh integration  against tests/defectdojo/docker-compose.yml (started
#                       by the CI job): SARIF import, identical re-import
#                       deduplicates, fixed re-import closes, Trivy import,
#                       root-cause tags on findings, SLA setup script
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
IMPORT="${ROOT}/.github/actions/defectdojo-import/import.sh"
F="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
URL="http://localhost:8080"

imp() {  # <file> <scan type> [VAR=value ...]: runs import.sh, outputs in $TMP/out
  local file="$1" type="$2"; shift 2
  : > "${TMP}/out"
  env GITHUB_OUTPUT="${TMP}/out" DD_URL="${DD_URL:-}" DD_TOKEN="${DD_TOKEN:-}" FILE="${file}" SCAN_TYPE="${type}" \
    PRODUCT=ci-fixture PRODUCT_TYPE=Sparkgeo ENGAGEMENT=ci ENVIRONMENT=staging TAGS="dependency:fixture, iac-module:modules/app" \
    MIN_SEVERITY=Info CLOSE_OLD=true PUSH_JIRA=false "$@" bash "${IMPORT}"
}
o() { grep "^$1=" "${TMP}/out" | cut -d= -f2-; }
api() { curl -sS --fail-with-body -H "Authorization: Token ${DD_TOKEN}" "${URL}/api/v2/$1"; }

case "${1:-}" in
  skip)
    DD_URL='' DD_TOKEN='' imp "${F}/findings.sarif" SARIF > /dev/null
    [ "$(o imported)" = "false" ] || fail "unconfigured import did not skip"
    if DD_URL=http://dd.example.com DD_TOKEN=x imp "${F}/findings.sarif" SARIF > /dev/null 2>&1; then
      fail "plain http to a remote host accepted"
    fi
    echo "skip checks passed"
    ;;
  integration)
    DD_TOKEN="$(curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' \
      -d '{"username":"admin","password":"ci-only-admin-password"}' "${URL}/api/v2/api-token-auth/" | jq -r .token)"
    export DD_URL="${URL}" DD_TOKEN

    echo "== first SARIF import creates the product, engagement, test and 2 findings"
    imp "${F}/findings.sarif" SARIF
    [ "$(o created)" = "2" ] || fail "created $(o created), want 2: $(cat "${TMP}/out")"
    test_id="$(o test-id)"

    echo "== identical re-import deduplicates"
    imp "${F}/findings.sarif" SARIF
    [ "$(o test-id)" = "${test_id}" ] || fail "re-import went to test $(o test-id), want ${test_id}"
    [ "$(o created)" = "0" ] || fail "re-import created: $(cat "${TMP}/out")"
    [ "$(o untouched)" = "2" ] || fail "re-import untouched: $(cat "${TMP}/out")"
    [ "$(api "findings/?test=${test_id}&active=true" | jq .count)" = "2" ] || fail "active findings after re-import"

    echo "== re-import without FX002 closes it (the Fix outcome)"
    imp "${F}/findings-fixed.sarif" SARIF
    [ "$(o closed)" = "1" ] || fail "fixed re-import: $(cat "${TMP}/out")"
    [ "$(api "findings/?test=${test_id}&active=true" | jq .count)" = "1" ] || fail "active findings after fix"

    echo "== Trivy import lands in its own test with the root-cause tags"
    imp "${F}/trivy.json" "Trivy Scan" TAGS="base-image:sha256:1111111111111111111111111111111111111111111111111111111111111111"
    [ "$(o created)" = "1" ] || fail "trivy: $(cat "${TMP}/out")"
    trivy_test="$(o test-id)"
    [ "${trivy_test}" != "${test_id}" ] || fail "trivy shared the SARIF test"
    tags="$(api "findings/?test=${trivy_test}" | jq -r '.results[0].tags | join(",")')"
    grep -q 'base-image:sha256:1111' <<< "${tags}" || fail "finding tags: ${tags}"
    grep -q 'env:staging' <<< "${tags}" || fail "env tag missing: ${tags}"
    [ "$(api "findings/?test=${trivy_test}" | jq -r '.results[0].severity')" = "High" ] || fail "trivy severity"

    echo "== SLA setup assigns the non-production configuration"
    bash "${ROOT}/docs/defectdojo-sla-setup.sh" non-production ci-fixture
    bash "${ROOT}/docs/defectdojo-sla-setup.sh" non-production ci-fixture > /dev/null  # idempotent
    sla="$(api "products/?name=ci-fixture" | jq -r '.results[0].sla_configuration')"
    cfg="$(api "sla_configurations/${sla}/")"
    [ "$(jq -r .name <<< "${cfg}")" = "Sparkgeo non-production" ] || fail "sla name: ${cfg}"
    [ "$(jq -r '[.critical,.high,.medium,.low]|join(",")' <<< "${cfg}")" = "7,30,90,90" ] || fail "sla days: ${cfg}"
    [ "$(api "sla_configurations/?limit=1000" | jq '[.results[] | select(.name | startswith("Sparkgeo"))] | length')" = "2" ] \
      || fail "SLA configurations duplicated"
    echo "all DefectDojo integration checks passed"
    ;;
  *) echo "usage: run.sh skip|integration" >&2; exit 2 ;;
esac
