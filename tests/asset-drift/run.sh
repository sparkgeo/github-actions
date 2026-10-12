#!/usr/bin/env bash
# Checks drift.py against recorded aws_tagging_resource rows and a register:
# untagged, unmanaged, orphaned and unmatchable sets, account filtering,
# report and outputs. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/steampipe/drift.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <name> [args]; sets rc; writes $TMP/<name>/{drift.json,report.md,log,out}
  local name="$1"; shift
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --live "${FIX}/live.json" --register "${FIX}/assets.json" \
      --output "${dir}/drift.json" --report "${dir}/report.md" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
d() { jq -r "$2" "${TMP}/$1/drift.json"; }
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== account 123456789012: untagged, unmanaged, orphaned, unmatchable"
run acct --account 123456789012
[ "${rc}" -eq 0 ] || fail "acct rc ${rc}: $(cat "${TMP}/acct/log")"
[ "$(d acct '.account')" = "123456789012" ] || fail "account recorded"
[ "$(d acct '.counts | "\(.live) \(.untagged) \(.unmanaged) \(.orphaned) \(.unmatchable)"')" = "5 2 2 1 1" ] || fail "counts $(d acct .counts)"
[ "$(d acct '.untagged[] | "\(.arn) \(.missing | join(","))"')" = "arn:aws:lambda:us-west-2:123456789012:function:legacy-cron owner,project,environment,data-class
arn:aws:s3:::prescient-logs-a project,environment,data-class" ] || fail "untagged: $(d acct '.untagged')"
[ "$(d acct '.unmanaged[].arn')" = "arn:aws:ec2:us-west-2:123456789012:vpc/vpc-0abc123
arn:aws:lambda:us-west-2:123456789012:function:legacy-cron" ] || fail "unmanaged: $(d acct '.unmanaged')"
[ "$(d acct '.orphaned[] | "\(.repo) \(.id) \(.identifier)"')" = "sparkgeo/prescient-infra aws_sqs_queue.gone prescient-events" ] || fail "orphaned: $(d acct '.orphaned')"
[ "$(d acct '.unmatchable[].id')" = "module.net.aws_vpc.main" ] || fail "unmatchable: $(d acct '.unmatchable')"
[ "$(d acct '.managed[] | "\(.arn) \(.id)"')" = "arn:aws:iam::123456789012:role/prescient-app aws_iam_role.app
arn:aws:s3:::prescient-ingest aws_s3_bucket.ingest
arn:aws:s3:::prescient-logs-a aws_s3_bucket.logs[\"a\"]" ] || fail "managed: $(d acct '.managed')"
[ "$(output acct untagged-count)" = "2" ] || fail "untagged-count output"
[ "$(output acct unmanaged-count)" = "2" ] || fail "unmanaged-count output"
[ "$(output acct orphaned-count)" = "1" ] || fail "orphaned-count output"
[ "$(output acct report-path)" = "${TMP}/acct/report.md" ] || fail "report-path output"
grep -q '^<!-- asset-drift -->' "${TMP}/acct/report.md" || fail "report marker"
grep -q '^## Asset drift, account 123456789012: 5 live resources, 2 untagged, 2 unmanaged, 1 orphaned' "${TMP}/acct/report.md" || fail "report heading: $(head -2 "${TMP}/acct/report.md")"
grep -qF 'arn:aws:lambda:us-west-2:123456789012:function:legacy-cron' "${TMP}/acct/report.md" || fail "report lists the unmanaged function"
grep -qF 'aws_sqs_queue.gone' "${TMP}/acct/report.md" || fail "report lists the orphan"
grep -q 'Asset drift' "${TMP}/acct/summary" || fail "step summary"
[ "$(grep -c '^::warning title=asset-drift::' "${TMP}/acct/log")" = "5" ] || fail "one warning per untagged, unmanaged and orphaned finding: $(grep -c '^::warning' "${TMP}/acct/log")"

echo "== no account filter: every live row and every register record"
run all
[ "${rc}" -eq 0 ] || fail "all rc ${rc}"
[ "$(d all '.counts | "\(.live) \(.orphaned)"')" = "6 2" ] || fail "all counts $(d all .counts)"

echo "== required-tags owner only"
run owner --account 123456789012 --required-tags owner
[ "$(d owner '.counts.untagged')" = "1" ] || fail "owner-only untagged $(d owner '.counts.untagged')"

echo "== usage errors exit 2"
set +e
python3 -I "${SCRIPT}" --live "${TMP}/missing.json" --register "${FIX}/assets.json" --output "${TMP}/x.json" --report "${TMP}/x.md" > "${TMP}/err.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "missing live rc ${rc}"
grep -q '^::error title=asset-drift::' "${TMP}/err.log" || fail "usage annotation"

echo "all asset-drift checks passed"
