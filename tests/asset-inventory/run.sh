#!/usr/bin/env bash
# Checks inventory.py: OpenTofu plan and CDK template parsers, tag violations,
# diff against a base inventory, DOT and Mermaid snapshots, JSON Schema.
# Needs python3 and jq; check-jsonschema and dot are used when present.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/.github/actions/asset-inventory/inventory.py"
SCHEMA="${ROOT}/docs/asset-inventory.schema.json"
FIX="${HERE}/fixtures"
CHECK_JSONSCHEMA="${CHECK_JSONSCHEMA:-check-jsonschema}"
NOW="2026-10-12T00:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "${SCHEMA}" ] || fail "missing ${SCHEMA}"

run() {  # <name> <stack> <input> [args]; sets rc; writes $TMP/<name>/{inventory.json,inventory.dot,inventory.mmd,report.md,log,out}
  local name="$1" stack="$2" input="$3"; shift 3
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --stack "${stack}" --input "${input}" --repo sparkgeo/prescient-infra --now "${NOW}" \
      --output "${dir}/inventory.json" --dot "${dir}/inventory.dot" --mermaid "${dir}/inventory.mmd" \
      --report "${dir}/report.md" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
inv() { jq -r "$2" "${TMP}/$1/inventory.json"; }
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== tofu: modules, for_each, count, data sources skipped, untaggable types"
run tofu tofu "${FIX}/tofu"
[ "${rc}" -eq 0 ] || fail "tofu rc ${rc}: $(cat "${TMP}/tofu/log")"
expected="$(cat <<'EOT'
stacks/dev google_storage_bucket.assets google_storage_bucket assets us-central1 -
stacks/prod aws_iam_role.app aws_iam_role app us-west-2 data-class,environment,owner,project
stacks/prod aws_s3_bucket.ingest aws_s3_bucket ingest us-west-2 -
stacks/prod aws_s3_bucket.logs["a"] aws_s3_bucket logs us-west-2 data-class,environment,project
stacks/prod aws_s3_bucket.logs["b"] aws_s3_bucket logs us-west-2 data-class,environment,project
stacks/prod module.net.aws_vpc.main aws_vpc main us-west-2 -
stacks/prod module.net.module.subnets.aws_subnet.private[0] aws_subnet private us-west-2 -
stacks/prod random_id.suffix random_id suffix null -
EOT
)"
actual="$(inv tofu '.resources[] | "\(.stack) \(.id) \(.type) \(.name) \(.region) \(if .tag_violations == [] then "-" else (.tag_violations | sort | join(",")) end)"')"
[ "${actual}" = "${expected}" ] || fail "tofu resources differ:
${actual}"
[ "$(inv tofu '.resources[] | select(.id == "aws_s3_bucket.ingest") | .tags["data-class"]')" = "confidential" ] || fail "tofu tags"
[ "$(inv tofu '.resources[] | select(.id == "google_storage_bucket.assets") | .tags.owner')" = "team-data" ] || fail "google labels read as tags"
[ "$(inv tofu '.resources[] | select(.id == "random_id.suffix") | .taggable')" = "false" ] || fail "random_id must be untaggable"
[ "$(inv tofu '.resources[] | select(.id == "aws_iam_role.app") | .taggable')" = "true" ] || fail "iam role taggable"
[ "$(inv tofu '.resources[0].source | "\(.repo) \(.path) \(.line)"')" = "sparkgeo/prescient-infra null null" ] || fail "tofu source has no positions"
[ "$(inv tofu '.resources[0].account')" = "null" ] || fail "account null without --account"
[ "$(inv tofu '.counts | "\(.resources) \(.taggable) \(.violations)"')" = "8 7 3" ] || fail "tofu counts $(inv tofu '.counts')"
[ "$(inv tofu '.stack_kind')" = "tofu" ] || fail "stack_kind"
[ "$(inv tofu '.generated_at')" = "${NOW}" ] || fail "generated_at"
[ "$(inv tofu '.required_tags | join(",")')" = "owner,project,environment,data-class" ] || fail "required_tags"
[ "$(output tofu resource-count)" = "8" ] || fail "resource-count output"
[ "$(output tofu violation-count)" = "3" ] || fail "violation-count output"
[ "$(output tofu report-path)" = "${TMP}/tofu/report.md" ] || fail "report-path output"
[ "$(grep -c '^::warning title=asset-inventory::' "${TMP}/tofu/log")" = "3" ] || fail "one warning per resource with violations"
grep -q '^<!-- asset-inventory -->' "${TMP}/tofu/report.md" || fail "report marker"
grep -q 'aws_iam_role.app' "${TMP}/tofu/report.md" || fail "report lists unowned assets"
grep -q 'asset-inventory' "${TMP}/tofu/summary" || fail "step summary"

echo "== tofu: --account and --required-tags"
run tofu2 tofu "${FIX}/tofu" --account 123456789012 --required-tags owner
[ "$(inv tofu2 '.resources[0].account')" = "123456789012" ] || fail "account"
[ "$(inv tofu2 '.counts.violations')" = "1" ] || fail "required-tags owner only: $(inv tofu2 '.counts.violations')"

echo "== cdk: templates, cdk path as source, taggable heuristics"
run cdk cdk "${FIX}/cdk/cdk.out"
[ "${rc}" -eq 0 ] || fail "cdk rc ${rc}: $(cat "${TMP}/cdk/log")"
expected="$(cat <<'EOT'
Prod AppRole4D5E6F AWS::IAM::Role true Prod/App/Role/Resource data-class,environment,owner,project
Prod Events7G8H9I AWS::SNS::Topic true Prod/Events/Resource data-class,project
Prod EventsPermission AWS::Lambda::Permission false Prod/Events/Permission -
Prod IngestBucket1A2B3C AWS::S3::Bucket true Prod/Ingest/Resource -
EOT
)"
actual="$(inv cdk '.resources[] | "\(.stack) \(.id) \(.type) \(.taggable) \(.source.path) \(if .tag_violations == [] then "-" else (.tag_violations | sort | join(",")) end)"')"
[ "${actual}" = "${expected}" ] || fail "cdk resources differ:
${actual}"
[ "$(inv cdk '.resources[] | select(.id == "Events7G8H9I") | .tags.owner')" = "bob@sparkgeo.com" ] || fail "cdk tags"
[ "$(inv cdk '.counts | "\(.resources) \(.taggable) \(.violations)"')" = "4 3 2" ] || fail "cdk counts $(inv cdk '.counts')"

echo "== diff against a base inventory"
run diff tofu "${FIX}/tofu" --diff-base "${FIX}/base-inventory.json"
[ "${rc}" -eq 0 ] || fail "diff rc ${rc}: $(cat "${TMP}/diff/log")"
[ "$(jq -r '.diff.added | join(",")' "${TMP}/diff/inventory.json")" = 'google_storage_bucket.assets,aws_s3_bucket.logs["a"],aws_s3_bucket.logs["b"],module.net.aws_vpc.main,module.net.module.subnets.aws_subnet.private[0],random_id.suffix' ] || fail "diff added: $(jq -c '.diff.added' "${TMP}/diff/inventory.json")"
[ "$(jq -r '.diff.removed | join(",")' "${TMP}/diff/inventory.json")" = "aws_sqs_queue.gone" ] || fail "diff removed"
[ "$(jq -r '.diff.retagged[] | "\(.id) \(.key) \(.before) \(.after)"' "${TMP}/diff/inventory.json")" = "aws_s3_bucket.ingest owner team-old team-platform" ] || fail "diff retagged: $(jq -c '.diff.retagged' "${TMP}/diff/inventory.json")"
grep -q '^## Asset inventory: 8 resources, 3 with missing tags' "${TMP}/diff/report.md" || fail "report heading: $(head -3 "${TMP}/diff/report.md")"
grep -qE '^\| `aws_s3_bucket.ingest` \| owner \| `team-old` \| \*\*`team-platform`\*\* \|' "${TMP}/diff/report.md" || fail "owner change must be bold in the report"
grep -q 'aws_sqs_queue.gone' "${TMP}/diff/report.md" || fail "removed in report"
[ "$(output diff added-count)" = "6" ] || fail "added-count output"

echo "== snapshots: DOT and Mermaid"
diff -u "${FIX}/expected/inventory.dot" "${TMP}/tofu/inventory.dot" || fail "DOT snapshot differs"
diff -u "${FIX}/expected/inventory.mmd" "${TMP}/tofu/inventory.mmd" || fail "Mermaid snapshot differs"
grep -q '```mermaid' "${TMP}/tofu/report.md" || fail "report embeds mermaid under the threshold"
run small tofu "${FIX}/tofu" --mermaid-max-nodes 3
! grep -q '```mermaid' "${TMP}/small/report.md" || fail "report must not embed mermaid above the threshold"
grep -q 'inventory.svg' "${TMP}/small/report.md" || fail "report points at the SVG when too large"
if command -v dot >/dev/null; then
  run svg tofu "${FIX}/tofu" --svg "${TMP}/svg/inventory.svg"
  grep -q '<svg' "${TMP}/svg/inventory.svg" || fail "svg render"
else
  echo "dot not installed; svg render skipped"
fi

echo "== schema"
if command -v "${CHECK_JSONSCHEMA}" >/dev/null; then
  "${CHECK_JSONSCHEMA}" --schemafile "${SCHEMA}" "${TMP}/tofu/inventory.json" "${TMP}/cdk/inventory.json" "${TMP}/diff/inventory.json" || fail "schema check"
else
  echo "check-jsonschema not installed; schema check skipped (CI installs it)"
fi

echo "== usage errors exit 2"
run badstack pulumi "${FIX}/tofu"
[ "${rc}" -eq 2 ] || fail "bad stack rc ${rc}"
run noinput tofu "${TMP}/nope"
[ "${rc}" -eq 2 ] || fail "missing input rc ${rc}"
mkdir -p "${TMP}/empty"
run empty tofu "${TMP}/empty"
[ "${rc}" -eq 0 ] || fail "empty input rc ${rc}: $(cat "${TMP}/empty/log")"
[ "$(inv empty '.counts.resources')" = "0" ] || fail "empty inventory"
grep -q '^::warning title=asset-inventory::no plan' "${TMP}/empty/log" || fail "empty warning"

echo "all asset-inventory checks passed"
