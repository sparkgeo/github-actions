#!/usr/bin/env bash
# Checks the verify-map composite's check.py: resolution of changed files to
# the example map (longest glob wins, tool inferred), the HIGH_RISK_GLOBS
# fallback without a map, high-risk paths with no rung (advisory and strict),
# the covers warning, the PR body table presence (advisory and required), and
# schema errors. Needs python3 with PyYAML and jsonschema (VERIFY_PYTHON; a
# venv is created here when unset) and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${ROOT}/.github/actions/verify-map/check.py"
SCHEMA="${ROOT}/policies/verification/verify.schema.json"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

if [ -z "${VERIFY_PYTHON:-}" ]; then
  python3 -m venv "${TMP}/env"
  "${TMP}/env/bin/python" -m pip install --quiet --disable-pip-version-check "pyyaml==6.0.3" "jsonschema==4.26.0"
  VERIFY_PYTHON="${TMP}/env/bin/python"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <changed> <map> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    "${VERIFY_PYTHON}" -I "${CHECK}" --changed "$2" --map "$3" --schema "${SCHEMA}" --output "${TMP}/$1.json" "${@:4}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
j() { jq -r "$2" "${TMP}/$1.json"; }

echo "== example map: tiles mapped high with three rungs, handler low, queue worker unmapped, README nothing"
run map "${FIX}/changed-mapped.txt" "${FIX}/verify.yml"
[ "${rc}" -eq 0 ] || fail "map rc ${rc}: $(cat "${TMP}/map.log")"
[ "$(j map '.files["src/tiles/quadkey.py"] | .risk + "|" + (.rungs | join(",")) + "|" + .tool')" = "high|contracts,symbolic,properties|python" ] || fail "tiles entry: $(j map '.files["src/tiles/quadkey.py"]')"
[ "$(j map '.files["src/api/handlers/upload.py"] | .risk + "|" + (.rungs | join(","))')" = "low|boundary-contracts" ] || fail "handler entry"
{ [ "$(j map '.files["internal/queue/worker.go"] | .mapped')" = "false" ] && [ "$(j map '.files["internal/queue/worker.go"].tool')" = "go" ]; } || fail "unmapped go file"
[ "$(j map '.mapped | join(",")')" = "src/api/handlers/upload.py,src/tiles/quadkey.py" ] || fail "mapped list"
[ "$(j map '.by_tool.python | join(",")')" = "src/api/handlers/upload.py,src/tiles/quadkey.py" ] || fail "by_tool"
[ "$(j map '.fallback')" = "false" ] || fail "fallback flag"
grep -q '^## Verification map: 4 changed file(s), 2 on mapped paths, 0 high-risk with no rung$' "${TMP}/map.summary" || fail "summary: $(head -1 "${TMP}/map.summary")"
[ "$(grep '^mapped-count=' "${TMP}/map.out" | cut -d= -f2)" = "2" ] || fail "mapped-count output"

echo "== implementation under a model's covers changed without the model: advisory"
run covers "${FIX}/changed-mapped.txt" "${FIX}/verify.yml"
grep -q '^::warning title=verify-map::internal/queue/worker.go changed but the model specs/retry.tla did not' "${TMP}/covers.log" || fail "covers warning: $(grep warning "${TMP}/covers.log")"
run model "${FIX}/changed-model.txt" "${FIX}/verify.yml"
grep -q 'changed but the model' "${TMP}/model.log" && fail "no covers warning when the model changed too"

echo "== no verify.yml: HIGH_RISK_GLOBS fallback; auth path is high with no rung; strict fails"
run fb "${FIX}/changed-fallback.txt" "${TMP}/absent.yml"
[ "${rc}" -eq 0 ] || fail "fallback rc ${rc}: $(cat "${TMP}/fb.log")"
[ "$(j fb '.fallback')" = "true" ] || fail "fallback true"
[ "$(j fb '.bare_high_risk | join(",")')" = "lib/auth/session.py" ] || fail "bare high risk: $(j fb .bare_high_risk)"
grep -q '^::warning title=verify-map::lib/auth/session.py: high-risk path with no rung in the HIGH_RISK_GLOBS fallback (no verify.yml)' "${TMP}/fb.log" || fail "fallback warning"
grep -q 'HIGH_RISK_GLOBS fallback' "${TMP}/fb.summary" || fail "fallback note in summary"
run fbs "${FIX}/changed-fallback.txt" "${TMP}/absent.yml" --strict-high-risk
{ [ "${rc}" -eq 1 ] && grep -q '^::error title=verify-map::lib/auth/session.py' "${TMP}/fbs.log"; } || fail "strict high risk"
run custom "${FIX}/changed-fallback.txt" "${TMP}/absent.yml" --high-risk-globs "docs/**"
[ "$(j custom '.bare_high_risk | join(",")')" = "docs/guide.md" ] || fail "custom globs"

echo "== PR body table: filled passes; placeholder-only is missing (advisory, then required)"
run tbl "${FIX}/changed-mapped.txt" "${FIX}/verify.yml" --pr-body "${FIX}/body-table.md" --require-table
{ [ "${rc}" -eq 0 ] && [ "$(j tbl '.table_rows')" = "1" ]; } || fail "filled table: $(cat "${TMP}/tbl.log")"
run empty "${FIX}/changed-mapped.txt" "${FIX}/verify.yml" --pr-body "${FIX}/body-empty.md"
{ [ "${rc}" -eq 0 ] && grep -q '^::warning title=verify-map::2 mapped path(s) changed but the PR body.s "## Verification" table is missing or empty' "${TMP}/empty.log"; } || fail "empty table advisory"
run req "${FIX}/changed-mapped.txt" "${FIX}/verify.yml" --pr-body "${FIX}/body-empty.md" --require-table
{ [ "${rc}" -eq 1 ] && grep -q '^::error title=verify-map::2 mapped path(s) changed' "${TMP}/req.log"; } || fail "required table"
run nomap "${FIX}/changed-fallback.txt" "${FIX}/verify.yml" --pr-body "${FIX}/body-empty.md" --require-table
[ "${rc}" -eq 0 ] || fail "no mapped path changed: the table is not required"

echo "== schema errors always fail"
run bad "${FIX}/changed-mapped.txt" "${FIX}/bad.yml"
[ "${rc}" -eq 1 ] || fail "bad map rc ${rc}"
for needle in "paths/0/risk: 'extreme' is not one of" "paths/0/rungs/0: 'magic' is not one of" "paths/1: 'glob' is a required property" "Additional properties are not allowed ('extra' was unexpected)"; do
  grep -q "$needle" "${TMP}/bad.log" || fail "schema error missing: $needle; got: $(jq -c .errors "${TMP}/bad.json")"
done

echo "all verify-map checks passed"
