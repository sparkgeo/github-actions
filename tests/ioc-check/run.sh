#!/usr/bin/env bash
# Checks ioc_check.py against fixture feeds and one source fixture per
# extractor row of issue #110. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${HERE}/../../.github/actions/ioc-check/ioc_check.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <name> <root> [extra args]; sets rc, writes $TMP/<name>/{findings.json,report.md,log,out}
  local name="$1" root="$2"; shift 2
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${CHECK}" --feeds-dir "${FIX}/feeds" --root "${root}" \
      --output "${dir}/findings.json" --report "${dir}/report.md" "$@" > "${dir}/log" 2>&1
  rc=$?
  set -e
}
field() { jq -r "$2" "${TMP}/$1/findings.json"; }
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

ALL="c2-ip,c2-domain,malware-url"

echo "== block on everything: every extractor row matches, exit 1"
run all "${FIX}/src" --block-on "${ALL}"
[ "${rc}" -eq 1 ] || fail "all rc ${rc}: $(cat "${TMP}/all/log")"
[ "$(field all .match_count)" = "9" ] || fail "all match_count $(field all .match_count): $(cat "${TMP}/all/log")"
[ "$(field all .blocking_count)" = "9" ] || fail "all blocking_count"
[ "$(output all match-count)" = "9" ] || fail "all match-count output"
[ "$(output all blocking-count)" = "9" ] || fail "all blocking-count output"
[ "$(output all report-path)" = "${TMP}/all/report.md" ] || fail "all report-path output"
expected="$(cat <<'EOT'
docker/Dockerfile:1 c2-domain threatfox registry.example
docker/Dockerfile:3 malware-url threatfox threatfox#1000003
go/go.mod:7 c2-domain threatfox c2.example
helm/values.yaml:4 c2-ip feodo 240.9.9.9
node/package.json:4 c2-domain threatfox c2.example
node/package.json:5 malware-url urlhaus urlhaus#3401
node/package.json:6 malware-url urlhaus https://mirror.example/
terraform/main.tf:3 c2-ip threatfox 240.1.2.3
terraform/main.tf:9 c2-domain threatfox c2.example
EOT
)"
actual="$(field all '.matches[] | "\(.file):\(.line) \(.category) \(.feed) \(.indicator)"' | sort)"
[ "${actual}" = "${expected}" ] || fail "all matches differ:
${actual}"
[ "$(field all '.matches[] | select(.file == "terraform/main.tf" and .line == 3) | .matched')" = "240.1.0.0/16" ] || fail "cidr containment reports the code CIDR"
[ "$(field all '.matches[] | select(.feed == "feodo") | .confidence')" = "100" ] || fail "confidence carried"
[ "$(field all '.matches[] | select(.feed == "feodo") | .first_seen')" = "2026-09-30T00:00:00Z" ] || fail "first_seen carried"
[ "$(field all '.snapshot.threatfox')" = "2026-10-07T05:17:40Z" ] || fail "snapshot fetched_at recorded"
[ "$(grep -c '^::error file=' "${TMP}/all/log")" = "9" ] || fail "all: expected 9 error annotations"
grep -q '^::error file=terraform/main.tf,line=3,title=ioc-check::' "${TMP}/all/log" || fail "annotation file/line"
grep -q 'ioc-check' "${TMP}/all/summary" || fail "step summary written"

echo "== redaction: URLs with a path never appear in logs, report or findings"
for f in log report.md findings.json summary; do
  ! grep -q 'payload.sh' "${TMP}/all/${f}" || fail "payload.sh leaked into ${f}"
  ! grep -q 'loader.bin' "${TMP}/all/${f}" || fail "loader.bin leaked into ${f}"
done
grep -q 'threatfox#1000003' "${TMP}/all/report.md" || fail "report lacks redacted threatfox id"
grep -q 'urlhaus#3401' "${TMP}/all/log" || fail "log lacks redacted urlhaus id"
grep -q 'https://mirror.example/' "${TMP}/all/report.md" || fail "host-only URL must not be redacted"
grep -q '^<!-- ioc-check -->' "${TMP}/all/report.md" || fail "report marker"
grep -q 'terraform/main.tf:9' "${TMP}/all/report.md" || fail "report file:line"

echo "== advisory: empty block-on warns and exits 0"
run advisory "${FIX}/src" --block-on ""
[ "${rc}" -eq 0 ] || fail "advisory rc ${rc}: $(cat "${TMP}/advisory/log")"
[ "$(field advisory .match_count)" = "9" ] || fail "advisory match_count"
[ "$(field advisory .blocking_count)" = "0" ] || fail "advisory blocking_count"
[ "$(grep -c '^::warning file=' "${TMP}/advisory/log")" = "9" ] || fail "advisory: expected 9 warnings"
! grep -q '^::error' "${TMP}/advisory/log" || fail "advisory must not emit errors"

echo "== block-on subset: only c2-ip blocks"
run subset "${FIX}/src" --block-on "c2-ip"
[ "${rc}" -eq 1 ] || fail "subset rc ${rc}"
[ "$(field subset .match_count)" = "9" ] || fail "subset match_count"
[ "$(field subset .blocking_count)" = "2" ] || fail "subset blocking_count $(field subset .blocking_count)"
[ "$(grep -c '^::error file=' "${TMP}/subset/log")" = "2" ] || fail "subset errors"
[ "$(grep -c '^::warning file=' "${TMP}/subset/log")" = "7" ] || fail "subset warnings"

echo "== paths and exclude globs"
run globs "${FIX}/src" --block-on "${ALL}" --paths '**/Dockerfile*,**/*.tf' --exclude 'terraform/**'
[ "${rc}" -eq 1 ] || fail "globs rc ${rc}"
[ "$(field globs '[.matches[].file] | unique | join(",")')" = "docker/Dockerfile" ] || fail "globs files $(field globs '[.matches[].file] | unique | join(",")')"

echo "== files-from: explicit file list (changed-only mode)"
printf 'helm/values.yaml\nmissing/file.yaml\n' > "${TMP}/list"
run listed "${FIX}/src" --block-on "${ALL}" --files-from "${TMP}/list"
[ "${rc}" -eq 1 ] || fail "listed rc ${rc}: $(cat "${TMP}/listed/log")"
[ "$(field listed .match_count)" = "1" ] || fail "listed match_count"

echo "== clean tree: no matches, exit 0, resolved report"
run clean "${FIX}/clean" --block-on "${ALL}"
[ "${rc}" -eq 0 ] || fail "clean rc ${rc}: $(cat "${TMP}/clean/log")"
[ "$(field clean .match_count)" = "0" ] || fail "clean match_count"
grep -q '^<!-- ioc-check -->' "${TMP}/clean/report.md" || fail "clean report marker"
grep -qi 'no indicators' "${TMP}/clean/report.md" || fail "clean report wording"

echo "== usage errors exit 2"
run badcat "${FIX}/src" --block-on "c2-ip,ransom"
[ "${rc}" -eq 2 ] || fail "bad category rc ${rc}"
grep -q '^::error title=ioc-check::' "${TMP}/badcat/log" || fail "bad category annotation"
set +e
python3 -I "${CHECK}" --feeds-dir "${TMP}/nope" --root "${FIX}/src" --output "${TMP}/x.json" --report "${TMP}/x.md" --block-on "" > "${TMP}/nofeeds.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "missing feeds rc ${rc}"

echo "all ioc-check checks passed"
