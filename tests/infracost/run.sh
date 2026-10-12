#!/usr/bin/env bash
# Checks gate.py against sample Infracost JSON: USD and percent caps, decreases,
# a zero base, the usage-file warning, outputs and exit codes. Needs python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/infracost/gate.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <name> <json> [args]; sets rc; writes $TMP/<name>/{log,out,summary,snippet.md}
  local name="$1" file="$2"; shift 2
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --json "${file}" --snippet "${dir}/snippet.md" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== comment-only: both caps zero"
run none "${FIX}/increase.json"
[ "${rc}" -eq 0 ] || fail "none rc ${rc}: $(cat "${TMP}/none/log")"
[ "$(output none monthly-diff)" = "150.00" ] || fail "monthly-diff $(output none monthly-diff)"
[ "$(output none monthly-total)" = "1150.00" ] || fail "monthly-total"
[ "$(output none percent-change)" = "15.0" ] || fail "percent-change $(output none percent-change)"
[ "$(output none gate)" = "comment-only" ] || fail "gate $(output none gate)"
[ "$(output none threshold)" = "none" ] || fail "threshold"
grep -qF "Cost gate: comment-only (no threshold set); monthly change +\$150.00 (+15.0%), new total \$1,150.00/month." "${TMP}/none/snippet.md" || fail "snippet: $(cat "${TMP}/none/snippet.md")"
grep -q '^::warning title=infracost::3 usage-based resources' "${TMP}/none/log" || fail "usage warning: $(cat "${TMP}/none/log")"
grep -qF 'infracost-usage.yml' "${TMP}/none/snippet.md" || fail "snippet carries the usage warning"
grep -q 'Cost gate' "${TMP}/none/summary" || fail "step summary"

echo "== USD cap"
run usd-fail "${FIX}/increase.json" --max-monthly-increase 100
[ "${rc}" -eq 1 ] || fail "usd-fail rc ${rc}"
[ "$(output usd-fail gate)" = "failed" ] || fail "usd-fail gate"
grep -q "^::error title=infracost::monthly increase \$150.00 exceeds the \$100.00 cap" "${TMP}/usd-fail/log" || fail "usd-fail error: $(cat "${TMP}/usd-fail/log")"
grep -qF "threshold applied: max monthly increase \$100.00 (exceeded)" "${TMP}/usd-fail/snippet.md" || fail "usd-fail snippet: $(cat "${TMP}/usd-fail/snippet.md")"
run usd-pass "${FIX}/increase.json" --max-monthly-increase 200
[ "${rc}" -eq 0 ] || fail "usd-pass rc ${rc}"
[ "$(output usd-pass gate)" = "passed" ] || fail "usd-pass gate"
grep -qF "threshold applied: max monthly increase \$200.00 (within)" "${TMP}/usd-pass/snippet.md" || fail "usd-pass snippet"

echo "== percent cap"
run pct-fail "${FIX}/increase.json" --max-percent-increase 10
[ "${rc}" -eq 1 ] || fail "pct-fail rc ${rc}"
grep -q '^::error title=infracost::monthly increase of 15.0% exceeds the 10% cap' "${TMP}/pct-fail/log" || fail "pct-fail error: $(cat "${TMP}/pct-fail/log")"
run pct-pass "${FIX}/increase.json" --max-percent-increase 20
[ "${rc}" -eq 0 ] || fail "pct-pass rc ${rc}"
run both "${FIX}/increase.json" --max-monthly-increase 200 --max-percent-increase 10
[ "${rc}" -eq 1 ] || fail "both: percent cap must still fail"
grep -qF "max monthly increase \$200.00 (within), max percent increase 10% (exceeded)" "${TMP}/both/snippet.md" || fail "both snippet: $(cat "${TMP}/both/snippet.md")"

echo "== decreases never fail"
run dec "${FIX}/decrease.json" --max-monthly-increase 1 --max-percent-increase 1
[ "${rc}" -eq 0 ] || fail "decrease rc ${rc}"
[ "$(output dec monthly-diff)" = "-200.00" ] || fail "decrease diff"
grep -qF "monthly change -\$200.00 (-20.0%)" "${TMP}/dec/snippet.md" || fail "decrease snippet: $(cat "${TMP}/dec/snippet.md")"

echo "== zero base"
run zero-pct "${FIX}/zero-base.json" --max-percent-increase 10
[ "${rc}" -eq 1 ] || fail "zero-base percent must count as exceeded"
[ "$(output zero-pct percent-change)" = "n/a" ] || fail "zero-base percent-change $(output zero-pct percent-change)"
run zero-usd "${FIX}/zero-base.json" --max-monthly-increase 100
[ "${rc}" -eq 0 ] || fail "zero-base usd rc ${rc}"
run flat "${FIX}/no-change.json" --max-monthly-increase 1 --max-percent-increase 1
[ "${rc}" -eq 0 ] || fail "no change rc ${rc}"

echo "== usage file"
run usage-ok "${FIX}/increase.json" --usage-file "${FIX}/infracost-usage.yml"
! grep -q '^::warning' "${TMP}/usage-ok/log" || fail "usage file present must not warn"
run usage-missing "${FIX}/increase.json" --usage-file "${TMP}/nope.yml"
grep -q '^::warning title=infracost::usage file .*nope.yml not found' "${TMP}/usage-missing/log" || fail "missing usage file warning: $(cat "${TMP}/usage-missing/log")"
run usage-none "${FIX}/no-change.json"
! grep -q '^::warning' "${TMP}/usage-none/log" || fail "no usage-based resources must not warn"

echo "== missing JSON exits 2"
run missing "${TMP}/nope.json"
[ "${rc}" -eq 2 ] || fail "missing rc ${rc}"

echo "== mkconfig.sh: plan list to infracost.yml"
MKCONFIG="${HERE}/../../.github/actions/infracost/mkconfig.sh"
mkdir -p "${TMP}/plans/stacks/prod" "${TMP}/plans/stacks/dev"
echo '{}' > "${TMP}/plans/stacks/prod/plan.json"
echo '{}' > "${TMP}/plans/stacks/dev/plan.json"
printf 'stacks/prod\nstacks/dev\n' > "${TMP}/stacks.txt"
bash "${MKCONFIG}" "${TMP}/stacks.txt" "${TMP}/plans" "${FIX}/infracost-usage.yml" > "${TMP}/infracost.yml"
diff -u - "${TMP}/infracost.yml" <<CFG || fail "mkconfig output differs"
version: "0.1"
projects:
  - path: ${TMP}/plans/stacks/prod/plan.json
    name: stacks/prod
    usage_file: ${FIX}/infracost-usage.yml
  - path: ${TMP}/plans/stacks/dev/plan.json
    name: stacks/dev
    usage_file: ${FIX}/infracost-usage.yml
CFG
printf 'stacks/prod\nstacks/gone\n' > "${TMP}/stacks2.txt"
bash "${MKCONFIG}" "${TMP}/stacks2.txt" "${TMP}/plans" "" > "${TMP}/infracost2.yml" 2> "${TMP}/mk.log"
grep -q 'name: stacks/prod' "${TMP}/infracost2.yml" || fail "mkconfig kept prod"
! grep -q 'stacks/gone' "${TMP}/infracost2.yml" || fail "mkconfig must skip stacks without a plan"
! grep -q 'usage_file' "${TMP}/infracost2.yml" || fail "mkconfig must omit usage_file when empty"
grep -q '^::notice title=infracost::stacks/gone has no plan' "${TMP}/mk.log" || fail "mkconfig notice: $(cat "${TMP}/mk.log")"
set +e
bash "${MKCONFIG}" "${TMP}/stacks2.txt" "${TMP}/nowhere" "" > /dev/null 2> "${TMP}/mk2.log"
rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "mkconfig with no plans at all must exit 1, got ${rc}"

echo "all infracost gate checks passed"
