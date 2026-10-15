#!/usr/bin/env bash
# Cost diff for CDK (issue #90): synth.sh on fixtures/app (one plain stack and
# one inside a Stage) must lay out <stack>/plan.json for each template, which
# mkconfig.sh turns into Infracost projects; unsupported.sh must total the
# not-estimated resource types. Infracost itself needs an API key and is not
# run here. Needs node/npx (npm ci of the fixture), jq and bash.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
ACT="${ROOT}/.github/actions/infracost"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }

: > "${WORK}/stacks"
bash "${ACT}/synth.sh" "${ROOT}" tests/cost-diff-cdk/fixtures/app node "${CDK_VERSION:-2.1145.0}" "--all" "${WORK}/plans" "${WORK}/stacks" > /dev/null
check "both stacks are listed, the staged one with its stage" "$(sort "${WORK}/stacks" | sed 's/[0-9A-F]\{8\}$//' | tr '\n' ' ')" "Shared Staging-StagingCompute "
check "each stack has a CloudFormation template as plan.json" \
  "$(for f in "${WORK}"/plans/*/plan.json; do jq -e '.Resources | length > 0' "${f}" > /dev/null && echo y; done | tr -d '\n')" "yy"
bash "${ACT}/mkconfig.sh" "${WORK}/stacks" "${WORK}/plans" infracost-usage.yml > "${WORK}/config.yml"
check "mkconfig.sh makes one project per stack" "$(grep -c '^  - path: .*/plan.json$' "${WORK}/config.yml")/$(grep -c 'usage_file: infracost-usage.yml' "${WORK}/config.yml")" "2/2"

bash "${ACT}/unsupported.sh" "${HERE}/fixtures/infracost-unsupported.json" > "${WORK}/summary.md"
check "unsupported resource types are totalled across stacks" \
  "$(grep -c -e 'AWS::S3::BucketPolicy. | 3 |$' -e 'AWS::EC2::EIP. | 1 |$' "${WORK}/summary.md")" "2"
echo '{"projects": [{"summary": {}}]}' > "${WORK}/none.json"
check "nothing unsupported says so" "$(bash "${ACT}/unsupported.sh" "${WORK}/none.json" | grep -c '^None:')" "1"

exit "${fail}"
