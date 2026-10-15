#!/usr/bin/env bash
# DR check for CDK (issue #94): report.py on a validation report recorded
# with cdk-nag 3.0.2 and aws-cdk-lib 2.273.0 from fixtures/app. The app has
# 8 resilience violations (RDS: backup plan, multi-AZ; DynamoDB: backup
# plan, PITR; S3: replication x3, versioning) and 2 acknowledged versioning
# findings, one with a real reason and one with "ok". Needs python3 and jq.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
# Stack frames were recorded with a placeholder for the app directory.
sed "s#@APP@#${HERE}/fixtures/app#g" "${HERE}/fixtures/validation-report.json" > "${WORK}/report.json"
cd "${ROOT}"
report() {
  status=0
  python3 -I .github/actions/cdk-nag/report.py --report "${WORK}/report.json" --comment "${WORK}/comment.md" "$@" \
    > "${WORK}/out" 2> "${WORK}/err" || status=$?
}
count() { grep "^$1-count=" "${WORK}/out" | cut -d= -f2; }

report --rules policies/dr/cdk-nag-rules.txt
check "default subset: 8 violations, 2 acknowledged, 1 weak, nothing strict" \
  "$(count violation)/$(count acknowledged)/$(count weak)/$(count blocking)/${status}" "8/2/1/0/0"
check "annotation points at the line that created the RDS instance" \
  "$(grep -c '^::warning file=tests/dr-check-cdk/fixtures/app/app.js,line=18,title=cdk-nag RDSMultiAZSupport::DrFixture/Database/Resource' "${WORK}/err")" "1"
check "the weak acknowledgement is reported" "$(grep -c "title=cdk-nag S3BucketVersioningEnabled acknowledged without a real reason::DrFixture/Cache/Resource: reason 'ok'" "${WORK}/err")" "1"
check "the PR comment carries its marker and the table" "$(grep -c -e '^<!-- dr-check-cdk -->$' -e 'RDSMultiAZSupport.*DrFixture/Database' "${WORK}/comment.md")" "2"

report --rules policies/dr/cdk-nag-rules.txt --strict RDSMultiAZSupport
check "strict RDSMultiAZSupport blocks" "$(count blocking)/${status}/$(grep -c '^::error .*RDSMultiAZSupport' "${WORK}/err")" "1/1/1"
report --rules policies/dr/cdk-nag-rules.txt --strict NIST.800.53.R5-S3BucketVersioningEnabled
check "strict versioning: the violation and the weak acknowledgement block, the real one does not" "$(count blocking)/${status}" "2/1"
report --rules DynamoDBPITREnabled
check "a custom rule list narrows the report" "$(count violation)/$(count acknowledged)" "1/0"
report --rules DynamoDBPITREnabled --strict RDSMultiAZSupport
check "a strict rule outside the list is added with a warning" "$(count blocking)/$(grep -c 'strict-rules not in the reported rules' "${WORK}/err")" "1/1"

exit "${fail}"
