#!/usr/bin/env bash
# Checks models.py (shared by the tlaplus and alloy composites): spec
# selection (changed specs, a changed .cfg, specs whose covered code changed,
# everything without a changed list, .tla without .cfg skipped), the TLC,
# Apalache and Alloy parsers on recorded violation output, the counterexample
# trace table, `expect` handling, the drift reminder and the gate. The CI job
# runs the tools live on the example and on fixtures/violated. Needs python3
# and jq.
# shellcheck disable=SC2016  # markdown backticks inside grep patterns
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PY="${ROOT}/.github/actions/tlaplus/models.py"
REC="${HERE}/fixtures/recorded"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
j() { jq -r "$2" "$1"; }

echo "== select: changed spec, changed cfg, covered code, all, tla without cfg skipped"
S="${TMP}/specs"; mkdir -p "${S}/proto" "${S}/authz"
touch "${S}/proto/Retry.tla" "${S}/proto/Retry.cfg" "${S}/proto/Draft.tla" "${S}/authz/tenancy.als" "${S}/proto/Queue.tla" "${S}/proto/Queue.cfg"
cd "${TMP}"
python3 -I "${PY}" select --specs-dir specs --output all.txt > /dev/null
[ "$(paste -sd, all.txt)" = "specs/authz/tenancy.als,specs/proto/Queue.tla,specs/proto/Retry.tla" ] || fail "all: $(paste -sd, all.txt)"
printf 'specs/proto/Retry.cfg\nsrc/app.py\n' > changed.txt
echo '{"stale_models": [{"model": "specs/authz/*.als", "code": ["src/authz/policy.py"]}]}' > map.json
python3 -I "${PY}" select --specs-dir specs --changed changed.txt --map map.json --output sel.txt --stale-output stale.json > sel.log
[ "$(paste -sd, sel.txt)" = "specs/authz/tenancy.als,specs/proto/Retry.tla" ] || fail "selected: $(paste -sd, sel.txt)"
grep -q '^  2 of 3 spec(s) selected; 1 model(s) whose covered code changed$' sel.log || fail "select line: $(cat sel.log)"
[ "$(j stale.json '.[0].model')" = "specs/authz/*.als" ] || fail "stale.json"

A="${TMP}/art"; mkdir -p "${A}"
echo "== tlc: violated invariant, named actions, state counts"
python3 -I "${PY}" tlc --log "${REC}/tlc-violation.txt" --spec specs/NoDedup.tla --rc 12 --output "${A}/tla-NoDedup.json" > "${A}/tlc.log"
[ "$(j "${A}/tla-NoDedup.json" '[.kind, .violation, (.trace|length), .trace[0].action, .trace[-1].action] | join(",")')" = "invariant,AppliedAtMostOnce,6,Initial predicate,Receive" ] || fail "tlc: $(j "${A}/tla-NoDedup.json" '{kind, violation, n: (.trace|length), a: [.trace[].action]}')"
[ "$(j "${A}/tla-NoDedup.json" '.trace[-1].vars.applied')" = "(k1 :> 2 @@ k2 :> 0)" ] || fail "trace vars"
grep -q '^::error file=specs/NoDedup.tla,title=TLC invariant::AppliedAtMostOnce$' "${A}/tlc.log" || fail "tlc annotation"
echo "Model checking completed. No error has been found." > "${TMP}/ok.txt"
python3 -I "${PY}" tlc --log "${TMP}/ok.txt" --spec specs/Ok.tla --rc 0 --output "${TMP}/tla-ok.json" > /dev/null
[ "$(j "${TMP}/tla-ok.json" '[.kind, .completed] | map(tostring) | join(",")')" = "null,true" ] || fail "tlc ok"
python3 -I "${PY}" tlc --log "${TMP}/ok.txt" --spec specs/Slow.tla --rc 124 --output "${TMP}/tla-slow.json" > /dev/null
[ "$(j "${TMP}/tla-slow.json" '.timeout')" = "true" ] || fail "tlc timeout"

echo "== apalache: a violation"
python3 -I "${PY}" apalache --log "${REC}/apalache-violation.txt" --spec specs/NoDedup.tla --rc 12 --output "${A}/apalache-NoDedup.json" > /dev/null
[ "$(j "${A}/apalache-NoDedup.json" '.outcome + ":" + .detail')" = "violation:State 4: state invariant 1 violated" ] || fail "apalache: $(cat "${A}/apalache-NoDedup.json")"

echo "== alloy: counterexample fails, expect 1 passes, vacuous run fails, instance kept"
python3 -I "${PY}" alloy --receipt "${REC}/alloy-leaky/receipt.json" --spec specs/leaky.als --solutions "${REC}/alloy-leaky" --output "${A}/alloy-leaky.json" > /dev/null
[ "$(j "${A}/alloy-leaky.json" '[.commands[] | .name + "=" + .verdict + ":" + (.failed|tostring)] | join(" ")')" = "NoCrossTenantAccess=counterexample:true KnownFlaw=counterexample:false Impossible=no instance (vacuous):true" ] || fail "alloy: $(j "${A}/alloy-leaky.json" '[.commands[] | {name, verdict, failed}]')"
j "${A}/alloy-leaky.json" '.commands[0].instance' | grep -q '^Command  *NoCrossTenantAccess$' || fail "instance text"

echo "== brief and gate"
cp "${TMP}/stale.json" "${A}/stale.json"
set +e
GITHUB_OUTPUT="${A}/out.txt" python3 -I "${PY}" brief --art "${A}" --gate > "${A}/brief.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "gate rc ${rc}"
[ "$(grep -c '^  FAIL: ' "${A}/brief.log")" = "4" ] || fail "fail count: $(cat "${A}/brief.log")"
grep -q 'warn: 1 model(s) whose covered code changed without them' "${A}/brief.log" || fail "stale warning"
grep -q '^| 6 | Receive | `inflight = {<<k1, 2>>}`<br>`applied = (k1 :> 2 @@ k2 :> 0)` |$' "${A}/verify-brief.md" || fail "trace row: $(grep '^| 6' "${A}/verify-brief.md")"
grep -q '^> \*\*Model drift review.\*\* Code a model covers changed but the model did not: `specs/authz/\*.als` covers `src/authz/policy.py`' "${A}/verify-brief.md" || fail "drift note"
grep -q '^```text$' "${A}/verify-brief.md" || fail "alloy instance block"
[ "$(j "${A}/summary.json" '[.tool, .tla, .alloy, .apalache, .counterexamples] | join(",")')" = "verify-models,1,1,1,2" ] || fail "summary.json: $(cat "${A}/summary.json")"
grep -q '^blocking=4$' "${A}/out.txt" || fail "outputs"

echo "all model checks passed"
