#!/usr/bin/env bash
# Checks rollup.py: merge of per-repo inventories, stale detection, unowned
# rules (tag violations, owner outside the team list), the derived markdown
# registers and the DOT snapshot. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/.github/actions/asset-register/rollup.py"
FIX="${HERE}/fixtures"
NOW="2026-10-12T06:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "${ROOT}/policies/tags/teams.yml" ] || fail "missing policies/tags/teams.yml"

run() {  # <name> <inventories> [args]; sets rc; writes $TMP/<name>/{assets.json,owners.md,unowned.md,data-classes.md,register.dot,summary.md,log,out}
  local name="$1" input="$2"; shift 2
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/stepsummary" \
    python3 -I "${SCRIPT}" --inventories "${input}" --output-dir "${dir}" --now "${NOW}" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
reg() { jq -r "$2" "${TMP}/$1/assets.json"; }
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== merge three repos with the team list"
run all "${FIX}/inventories" --teams "${FIX}/teams.yml" --stale-days 7
[ "${rc}" -eq 0 ] || fail "all rc ${rc}: $(cat "${TMP}/all/log")"
[ "$(reg all '.counts | "\(.repos) \(.assets) \(.unowned) \(.stale_repos)"')" = "3 6 2 1" ] || fail "counts $(reg all .counts)"
[ "$(reg all '.repos[] | "\(.repo) \(.stack_kind) \(.resources) \(.violations) \(.stale)"' | sort)" = "sparkgeo/clean-repo tofu 1 0 false
sparkgeo/geo-api cdk 2 0 true
sparkgeo/prescient-infra tofu 3 1 false" ] || fail "repo rows: $(reg all '.repos')"
[ "$(reg all '.assets[] | "\(.repo) \(.id)"')" = "sparkgeo/clean-repo google_storage_bucket.lake
sparkgeo/geo-api ApiFunction1A2B
sparkgeo/geo-api AssetsBucket3C4D
sparkgeo/prescient-infra aws_s3_bucket.ingest
sparkgeo/prescient-infra aws_s3_bucket.logs
sparkgeo/prescient-infra module.net.aws_vpc.main" ] || fail "assets order"
[ "$(reg all '.assets[] | select(.id == "aws_s3_bucket.logs") | .unowned_reason')" = "missing project, environment, data-class" ] || fail "violation reason"
[ "$(reg all '.assets[] | select(.id == "ApiFunction1A2B") | .unowned_reason')" = "owner team-unknown is not in policies/tags/teams.yml" ] || fail "team reason: $(reg all '.assets[] | select(.id == "ApiFunction1A2B") | .unowned_reason')"
[ "$(reg all '.assets[] | select(.id == "AssetsBucket3C4D") | .unowned_reason')" = "null" ] || fail "email owner must pass"
[ "$(reg all .generated_at)" = "${NOW}" ] || fail "generated_at"
[ "$(reg all .stale_days)" = "7" ] || fail "stale_days"
[ "$(output all repo-count)" = "3" ] || fail "repo-count output"
[ "$(output all unowned-count)" = "2" ] || fail "unowned-count output"
[ "$(output all stale-count)" = "1" ] || fail "stale-count output"
grep -q '^::warning title=asset-register::sparkgeo/geo-api inventory is 22 days old' "${TMP}/all/log" || fail "stale warning: $(cat "${TMP}/all/log")"

echo "== derived registers"
grep -q '^| team-platform | prescient | prod | 2 |' "${TMP}/all/owners.md" || fail "owners.md row: $(cat "${TMP}/all/owners.md")"
grep -q '^| team-platform | (none) | (none) | 1 |' "${TMP}/all/owners.md" || fail "owners.md untagged row"
grep -q '^| bob@sparkgeo.com | geo-api | dev | 1 |' "${TMP}/all/owners.md" || fail "owners.md email row"
[ "$(grep -c '^| sparkgeo/' "${TMP}/all/unowned.md")" = "2" ] || fail "unowned.md rows: $(cat "${TMP}/all/unowned.md")"
grep -qF "| sparkgeo/geo-api | \`ApiFunction1A2B\` | team-unknown | owner team-unknown is not in policies/tags/teams.yml |" "${TMP}/all/unowned.md" || fail "unowned.md team row"
[ "$(grep -c '^| sparkgeo/' "${TMP}/all/data-classes.md")" = "2" ] || fail "data-classes.md must list confidential and restricted only: $(cat "${TMP}/all/data-classes.md")"
grep -qF "| sparkgeo/prescient-infra | \`module.net.aws_vpc.main\` | aws_vpc | restricted | team-platform |" "${TMP}/all/data-classes.md" || fail "data-classes.md row"
grep -q '^## Asset register: 6 assets across 3 repos, 2 unowned, 1 stale inventory' "${TMP}/all/summary.md" || fail "summary heading: $(head -2 "${TMP}/all/summary.md")"
grep -q 'sparkgeo/geo-api' "${TMP}/all/summary.md" || fail "summary names the stale repo"
grep -q 'Asset register' "${TMP}/all/stepsummary" || fail "step summary"
diff -u "${FIX}/expected/register.dot" "${TMP}/all/register.dot" || fail "DOT snapshot differs"
[ -f "${TMP}/all/SHA256SUMS" ] || fail "SHA256SUMS written"
( cd "${TMP}/all" && sha256sum -c --quiet SHA256SUMS ) || fail "SHA256SUMS verifies"

echo "== no team list: any team-* owner is accepted"
run noteams "${FIX}/inventories"
[ "${rc}" -eq 0 ] || fail "noteams rc ${rc}: $(cat "${TMP}/noteams/log")"
[ "$(reg noteams .counts.unowned)" = "1" ] || fail "noteams unowned $(reg noteams .counts.unowned)"

echo "== high value, exposure and KRIs"
run hv "${FIX}/inventories" --teams "${FIX}/teams.yml" --high-value "${FIX}/high-value.json" --easm-findings "${FIX}/easm-findings.json"
[ "${rc}" -eq 0 ] || fail "hv rc ${rc}: $(cat "${TMP}/hv/log")"
[ "$(reg hv '.assets[] | select(.id == "aws_s3_bucket.ingest") | "\(.exposure) \(.high_value) \(.high_value_reason)"')" = "internal true production confidential data" ] || fail "prod confidential is high value"
[ "$(reg hv '.assets[] | select(.id == "module.net.aws_vpc.main") | .high_value_reason')" = "production restricted data" ] || fail "prod restricted"
[ "$(reg hv '.assets[] | select(.id == "ApiFunction1A2B") | "\(.exposure) \(.high_value)"')" = "public false" ] || fail "dev public lambda is not high value (not prod, not client-facing type)"
[ "$(reg hv '.assets[] | select(.id == "AssetsBucket3C4D") | .high_value_reason')" = "listed in policies/tags/high-value.json" ] || fail "forced by the list"
[ "$(reg hv '.assets[] | select(.id == "google_storage_bucket.lake") | "\(.exposure) \(.high_value)"')" = "internal false" ] || fail "exposure defaults to internal"
[ "$(reg hv '.counts | "\(.high_value) \(.unowned_high_value) \(.public)"')" = "3 1 1" ] || fail "hv counts $(reg hv .counts)"
[ "$(reg hv '.high_value_external | length')" = "2" ] || fail "external list carried"
grep -qF "| sparkgeo/prescient-infra | \`aws_s3_bucket.ingest\` | aws_s3_bucket | internal | team-platform | production confidential data |" "${TMP}/hv/high-value.md" || fail "high-value.md row: $(cat "${TMP}/hv/high-value.md")"
grep -qF "| Billing | billing | **(none)** |" "${TMP}/hv/high-value.md" || fail "external without owner is marked"
kri() { jq -r "$1" "${TMP}/hv/kri.json"; }
[ "$(kri '.indicators.unowned_high_value_assets | "\(.value) \(.threshold) \(.breached)"')" = "1 0 true" ] || fail "unowned high value KRI (the Billing entry has no owner)"
[ "$(kri '.indicators.unknown_internet_facing_assets | "\(.value) \(.threshold) \(.breached)"')" = "5 3 true" ] || fail "unknown assets KRI from the EASM findings"
[ "$(kri '.indicators.unowned_assets | "\(.value) \(.breached)"')" = "2 true" ] || fail "unowned KRI"
[ "$(kri '.indicators.stale_inventories | "\(.value) \(.breached)"')" = "1 true" ] || fail "stale KRI"
[ "$(kri '.indicators.agents_without_owner_or_kill_switch.value')" = "null" ] || fail "agent KRI unset"
[ "$(kri '.breached | join(",")')" = "stale_inventories,unknown_internet_facing_assets,unowned_assets,unowned_high_value_assets" ] || fail "breached list $(kri .breached)"
[ "$(output hv high-value-count)" = "3" ] || fail "high-value-count output"
[ "$(output hv kri-breached)" = "stale_inventories,unknown_internet_facing_assets,unowned_assets,unowned_high_value_assets" ] || fail "kri-breached output"
grep -q '^3 high-value assets (1 without an owner), 1 tagged public. KRIs breached: ' "${TMP}/hv/summary.md" || fail "summary KRI line: $(sed -n 3p "${TMP}/hv/summary.md")"
grep -q ' high-value.md$' "${TMP}/hv/SHA256SUMS" || fail "checksums must cover high-value.md"
grep -q ' kri.json$' "${TMP}/hv/SHA256SUMS" || fail "checksums must cover kri.json"

echo "== KRIs without EASM findings or a high-value file"
run nohv "${FIX}/inventories" --teams "${FIX}/teams.yml"
[ "$(jq -r '.indicators.unknown_internet_facing_assets | "\(.value) \(.breached) \(.source)"' "${TMP}/nohv/kri.json")" = "null false no EASM findings given" ] || fail "unknown KRI unset without findings"
[ "$(reg nohv '.counts.high_value')" = "2" ] || fail "derived high value only"
[ "$(reg nohv '.high_value_external | length')" = "0" ] || fail "no external list"
[ "$(output nohv kri-breached)" = "stale_inventories,unowned_assets" ] || fail "breached without hv: $(output nohv kri-breached)"

echo "== stale-days 30: nothing stale"
run fresh "${FIX}/inventories" --stale-days 30
[ "$(reg fresh .counts.stale_repos)" = "0" ] || fail "stale-days 30"

echo "== empty input: empty register, exit 0"
mkdir -p "${TMP}/none"
run empty "${TMP}/none"
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}: $(cat "${TMP}/empty/log")"
[ "$(reg empty '.counts | "\(.repos) \(.assets)"')" = "0 0" ] || fail "empty counts"
grep -q '^::warning title=asset-register::no inventories found' "${TMP}/empty/log" || fail "empty warning"
grep -q '^## Asset register: 0 assets across 0 repos' "${TMP}/empty/summary.md" || fail "empty summary"

echo "== unreadable inventory is skipped with a warning"
mkdir -p "${TMP}/bad/broken" && echo '{' > "${TMP}/bad/broken/inventory.json"
cp -r "${FIX}/inventories/clean-repo" "${TMP}/bad/"
run bad "${TMP}/bad"
[ "${rc}" -eq 0 ] || fail "bad rc ${rc}"
[ "$(reg bad .counts.repos)" = "1" ] || fail "broken inventory must be skipped"
grep -q '^::warning title=asset-register::broken/inventory.json' "${TMP}/bad/log" || fail "broken warning: $(cat "${TMP}/bad/log")"

echo "all asset-register checks passed"
