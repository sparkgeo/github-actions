#!/usr/bin/env bash
# Checks the privado composite's report.py against a privado.json recorded
# from the fixture app (tests/pii-dataflow/fixtures/app) and against a
# trimmed baseline: the summary, the baseline diff, the new-third-party gate
# and the PR comment body. The live scan with the privado image runs in the
# CI job. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
REPORT="${ROOT}/.github/actions/privado/report.py"
FIX="${HERE}/fixtures/privado.json"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${REPORT}" --report "${FIX}" --output "${TMP}/$1.json" --comment "${TMP}/$1.md" "${@:2}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}

echo "== recorded fixture report, no baseline"
run plain
[ "${rc}" -eq 0 ] || fail "plain rc ${rc}: $(cat "${TMP}/plain.log")"
[ "$(jq -r '.sources | length' "${TMP}/plain.json")" = "3" ] || fail "three data elements"
[ "$(jq -r '.destinations | join(",")' "${TMP}/plain.json")" = "https://api.example-crm.com/v1/contacts" ] || fail "third-party destination: $(jq -c .destinations "${TMP}/plain.json")"
[ "$(jq -r '.sinks.third_parties | keys | join(",")' "${TMP}/plain.json")" = "Sinks.ThirdParties.API.api.example-crm.com" ] || fail "third-party sink id"
[ "$(jq -r '.sinks.leakages | keys | join(",")' "${TMP}/plain.json")" = "Leakages.Log.Info" ] || fail "leakage sink"
[ "$(jq -r '.sinks.third_parties["Sinks.ThirdParties.API.api.example-crm.com"].files[0]' "${TMP}/plain.json")" = "app.py:17" ] || fail "file path relative to the code root: $(jq -c '.sinks.third_parties[].files' "${TMP}/plain.json")"
[ "$(jq -r '.baseline' "${TMP}/plain.json")" = "false" ] || fail "no baseline flag"
grep -q '^## PII data flow: 3 data element(s), 2 sink(s), 1 third-party destination(s), ' "${TMP}/plain.summary" || fail "summary heading: $(head -1 "${TMP}/plain.summary")"
grep -q '^| Email Address | - | Leakages.Log.Info\|^| Email Address | - | Log Info' "${TMP}/plain.summary" || fail "email row: $(grep 'Email Address' "${TMP}/plain.summary" | head -1)"
grep -q '^No baseline' "${TMP}/plain.summary" || fail "no-baseline note"
head -1 "${TMP}/plain.md" | grep -q '^<!-- pii-dataflow -->$' || fail "comment marker"
[ "$(grep '^source-count=' "${TMP}/plain.out" | cut -d= -f2)" = "3" ] || fail "source-count output"

echo "== baseline without the phone element and without the CRM call: the diff lists them; the gate fails"
jq '.sources |= map(select(.id != "Data.Sensitive.ContactData.PhoneNumber")) | .dataFlow.third_parties = []' "${FIX}" > "${TMP}/baseline.json"
run diff --baseline "${TMP}/baseline.json" --fail-on-new-sinks
[ "${rc}" -eq 1 ] || fail "new third party must fail the job: $(cat "${TMP}/diff.log")"
[ "$(jq -r '.new.sources | join(",")' "${TMP}/diff.json")" = "Data.Sensitive.ContactData.PhoneNumber" ] || fail "new source"
[ "$(jq -r '.new.sinks.third_parties | join(",")' "${TMP}/diff.json")" = "Sinks.ThirdParties.API.api.example-crm.com" ] || fail "new third-party sink"
[ "$(jq -r '.new.destinations | join(",")' "${TMP}/diff.json")" = "https://api.example-crm.com/v1/contacts" ] || fail "new destination"
grep -q '^::error title=pii-dataflow::new third-party data flow Sinks.ThirdParties.API.api.example-crm.com to https://api.example-crm.com/v1/contacts$' "${TMP}/diff.log" || fail "error annotation: $(grep '::' "${TMP}/diff.log")"
grep -q 'this fails the job' "${TMP}/diff.summary" || fail "gate note in summary"
grep -q '\*\*(new)\*\*' "${TMP}/diff.summary" || fail "new marker on the sink row"
[ "$(grep '^new-third-party-count=' "${TMP}/diff.out" | cut -d= -f2)" = "2" ] || fail "new-third-party-count output"

echo "== same diff without the gate: warning, exit 0"
run warn --baseline "${TMP}/baseline.json"
[ "${rc}" -eq 0 ] || fail "warn rc ${rc}"
grep -q '^::warning title=pii-dataflow::new third-party data flow' "${TMP}/warn.log" || fail "warning annotation"

echo "== identical baseline: nothing new, gate passes"
run same --baseline "${FIX}" --fail-on-new-sinks
[ "${rc}" -eq 0 ] || fail "same rc ${rc}"
[ "$(jq -r '[.new.sources, .new.destinations, .new.flows] | map(length) | add' "${TMP}/same.json")" = "0" ] || fail "nothing new"

echo "== missing report is an error"
set +e; python3 -I "${REPORT}" --report "${TMP}/nope.json" > "${TMP}/nope.log" 2>&1; rc=$?; set -e
{ [ "${rc}" -eq 1 ] && grep -q '^::error title=pii-dataflow::no privado report' "${TMP}/nope.log"; } || fail "missing report"

echo "all pii-dataflow checks passed"
