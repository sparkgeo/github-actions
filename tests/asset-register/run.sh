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
