#!/usr/bin/env bash
# Checks the EPSS/KEV/LEV override (#80) against recorded osv-scanner 2.4.0
# output and fixture feeds built with the threat-feeds normaliser, then runs
# the adjusted file through the shared severity gate. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
OVR="${ROOT}/.github/actions/epss-kev-override/override.py"
NORM="${ROOT}/.github/actions/threat-feeds/normalize.py"
GATE="${ROOT}/.github/actions/severity-gate/gate.sh"
FIX="${HERE}/fixtures"
LODASH="${ROOT}/tests/severity-gate/fixtures/osv-node-cvss-8.1.json"
MAL="${ROOT}/tests/osv-scanner/fixtures/osv-mal-and-cve.json"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Feeds in the mirror's envelope: today's kev + epss, and two older epss.
mkdir -p "${TMP}/feeds"
python3 -I "${NORM}" --feed kev --input "${FIX}/kev.json" --output "${TMP}/feeds/kev.json" --now 2026-10-07T13:00:00Z
python3 -I "${NORM}" --feed epss --input "${FIX}/epss-2026-10-07.csv" --output "${TMP}/feeds/epss.json" --now 2026-10-07T13:00:00Z
for d in 2026-08-08 2026-09-07; do
  python3 -I "${NORM}" --feed epss --input "${FIX}/epss-${d}.csv" --output "${TMP}/epss-${d}.json" --now "${d}T13:00:00Z"
done
HIST=("${TMP}/epss-2026-08-08.json" "${TMP}/epss-2026-09-07.json")

run() {  # <findings> <out> [args]; sets rc
  local in="$1" out="$2"; shift 2
  set +e
  GITHUB_OUTPUT="${TMP}/gh-output" python3 -I "${OVR}" --findings "${in}" --output "${TMP}/${out}.json" \
    --feeds-dir "${TMP}/feeds" --snapshot-tag threat-feeds-2026-10-07 "$@" > "${TMP}/${out}.log" 2>&1
  rc=$?
  set -e
}
sev() {  # <out> <cve>: adjusted max_severity of the group holding that CVE
  jq -r --arg c "$2" '.results[].packages[].groups[] | select(.aliases | index($c)) | .max_severity' "${TMP}/$1.json"
}
ov() { jq -r --arg c "$2" ".results[].packages[].groups[] | select(.aliases | index(\$c)) | .override | $3" "${TMP}/$1.json"; }
gate() {  # <out> <fail-on>; prints the gate's exit code
  set +e
  GITHUB_OUTPUT="${TMP}/gate-output" FINDINGS_FILE="${TMP}/$1.json" FORMAT=osv-json FAIL_ON="$2" bash "${GATE}" > /dev/null 2>&1
  echo $?
  set -e
}

echo "== defaults with history: KEV, EPSS and LEV each raise one group to critical"
run "${LODASH}" up --epss-history "${HIST[@]}"
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${TMP}/up.log")"
[ "$(sev up CVE-2020-28500)" = "9.0" ] || fail "KEV-listed 5.3 not raised"
[ "$(sev up CVE-2025-13465)" = "9.0" ] || fail "EPSS 0.15 6.9 not raised"
[ "$(sev up CVE-2020-8203)" = "9.0" ] || fail "LEV 0.62 7.4 not raised"
[ "$(sev up CVE-2021-23337)" = "8.1" ] || fail "8.1 changed without downgrade"
[ "$(ov up CVE-2020-28500 '.applied | join(",")')" = "up:kev" ] || fail "kev reason"
[ "$(ov up CVE-2025-13465 '.applied | join(",")')" = "up:epss" ] || fail "epss reason"
[ "$(ov up CVE-2020-8203 '.applied | join(",")')" = "up:lev" ] || fail "lev reason"
[ "$(ov up CVE-2020-8203 '.cves["CVE-2020-8203"].lev')" = "0.620633" ] || fail "LEV value $(ov up CVE-2020-8203 '.cves["CVE-2020-8203"].lev')"
[ "$(ov up CVE-2020-28500 '.original_max_severity')" = "5.3" ] || fail "original score"
[ "$(ov up CVE-2020-28500 '.snapshot')" = "threat-feeds-2026-10-07" ] || fail "snapshot tag"
[ "$(ov up CVE-2020-28500 '.cves["CVE-2020-28500"].kev_date_added')" = "2026-09-30" ] || fail "KEV date"
[ "$(ov up CVE-2020-28500 '.ssvc.exploitation')" = "active" ] || fail "SSVC exploitation"
[ "$(ov up CVE-2020-28500 '.ssvc.automatable')" = "yes" ] || fail "SSVC automatable (AV:N/PR:N/UI:N)"
[ "$(ov up CVE-2021-23337 '.ssvc.automatable')" = "yes" ] || fail "SSVC automatable: one advisory in the group is PR:N"
[ "$(ov up CVE-2021-23337 '.ssvc | has("exploitation")')" = "false" ] || fail "exploitation set without KEV"
grep -q '^uplifted=3$' "${TMP}/gh-output" || fail "uplifted output: $(cat "${TMP}/gh-output")"
[ "$(gate up critical)" = "1" ] || fail "gate passed a raised finding"

echo "== KEV off, higher EPSS threshold, no history: nothing moves"
run "${LODASH}" none --kev false --epss-threshold 0.5
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${TMP}/none.log")"
[ "$(sev none CVE-2020-28500)" = "5.3" ] || fail "KEV toggle ignored"
[ "$(sev none CVE-2020-8203)" = "7.4" ] || fail "LEV used without history"
[ "$(ov none CVE-2020-8203 '.cves["CVE-2020-8203"].lev')" = "null" ] || fail "LEV should be unknown"
[ "$(gate none critical)" = "0" ] || fail "gate failed with no critical"
[ "$(gate none high)" = "1" ] || fail "high gate should still fail on 8.1"

echo "== downgrade with history: 8.1 with EPSS < 0.01, not on KEV, LEV < 0.1 drops to medium"
run "${LODASH}" down --epss-history "${HIST[@]}" --downgrade true
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${TMP}/down.log")"
[ "$(sev down CVE-2021-23337)" = "4.0" ] || fail "8.1 not lowered: $(sev down CVE-2021-23337)"
[ "$(ov down CVE-2021-23337 '.applied | join(",")')" = "down:likelihood" ] || fail "downgrade reason"
[ "$(sev down CVE-2026-2950)" = "9.0" ] || fail "uplift lost under downgrade"
grep -q '^downgraded=1$' "${TMP}/gh-output" || fail "downgraded output"

echo "== automatable is no when every vector needs privileges or interaction"
jq '(.results[].packages[].vulnerabilities[] | select(.id == "GHSA-r5fr-rjxr-66jc") | .severity[].score) |= sub("PR:N"; "PR:H")' \
  "${LODASH}" > "${TMP}/lodash-prh.json"
run "${TMP}/lodash-prh.json" prh
[ "$(ov prh CVE-2021-23337 '.ssvc.automatable')" = "no" ] || fail "SSVC automatable (PR:H only)"

echo "== downgrade without history: LEV unknown, nothing lowered"
run "${LODASH}" nohist --downgrade true
[ "$(sev nohist CVE-2021-23337)" = "8.1" ] || fail "lowered without LEV"

echo "== runtime relevance: not-loaded CVEs drop one row after the uplift"
run "${LODASH}" rt --runtime-relevance "${FIX}/runtime-relevance.json"
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${TMP}/rt.log")"
[ "$(sev rt CVE-2020-28500)" = "7.0" ] || fail "KEV + not loaded should land at high"
[ "$(ov rt CVE-2020-28500 '.applied | join(",")')" = "up:kev,down:runtime-relevance" ] || fail "runtime reasons"
[ "$(sev rt CVE-2021-23337)" = "4.0" ] || fail "not-loaded 8.1 should drop to medium"
[ "$(sev rt CVE-2025-13465)" = "9.0" ] || fail "no export entry, must not drop"

echo "== malicious-package advisories pass through and still block"
run "${MAL}" mal --epss-history "${HIST[@]}"
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${TMP}/mal.log")"
[ "$(jq '[.results[].packages[].groups[] | select(.ids[0] | startswith("MAL-")) | has("override")] | any' "${TMP}/mal.json")" = "false" ] || fail "MAL group annotated"
[ "$(gate mal none)" = "1" ] || fail "MAL-* no longer blocks"

echo "== wrong feed in feeds-dir is rejected"
cp "${TMP}/feeds/kev.json" "${TMP}/feeds/epss.json"
run "${LODASH}" bad
[ "${rc}" -eq 1 ] || fail "accepted a kev envelope as epss (rc ${rc})"

echo "all epss-kev-override checks passed"
