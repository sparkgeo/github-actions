#!/usr/bin/env bash
# Checks reputation.py: lockfile diffing for every supported format against a
# throwaway git repo, and the gates against a seeded deps.dev cache (offline).
# Needs python3 >= 3.11, jq and git.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/dependency-reputation/reputation.py"
FIX="${HERE}/fixtures"
NOW="2026-10-12T00:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Throwaway repo: base commit holds fixtures/base, head commit holds fixtures/head.
REPO="${TMP}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.email t@example.com
git -C "${REPO}" config user.name t
cp "${FIX}"/base/* "${REPO}/"
git -C "${REPO}" add -A && git -C "${REPO}" commit -q -m base
BASE="$(git -C "${REPO}" rev-parse HEAD)"
git -C "${REPO}" rm -q -r --cached . >/dev/null && rm -f "${REPO}"/*
cp "${FIX}"/head/* "${REPO}/"
git -C "${REPO}" add -A && git -C "${REPO}" commit -q -m head

run() {  # <name> [args]; sets rc, writes $TMP/<name>/{findings.json,report.md,log,out}
  local name="$1"; shift
  local dir="${TMP}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/out"
  set +e
  ( cd "${REPO}" && GITHUB_OUTPUT="${dir}/out" GITHUB_STEP_SUMMARY="${dir}/summary" \
    python3 -I "${SCRIPT}" --cache-dir "${FIX}/cache" --offline --now "${NOW}" \
      --output "${dir}/findings.json" --report "${dir}/report.md" "$@" ) > "${dir}/log" 2>&1
  rc=$?
  set -e
}
field() { jq -r "$2" "${TMP}/$1/findings.json"; }
output() { grep "^$2=" "${TMP}/$1/out" | cut -d= -f2-; }

echo "== all gates: added packages from every lockfile, malicious and low score block"
run all --base-sha "${BASE}" --min-scorecard 5 --max-age-days 730 --fail-on-malicious true
[ "${rc}" -eq 1 ] || fail "all rc ${rc}: $(cat "${TMP}/all/log")"
expected="$(cat <<'EOT'
CARGO serde 1.0.210 Cargo.lock
GO github.com/x/y v1.2.3 go.sum
NPM evil-stream 0.1.1 pnpm-lock.yaml
NPM left-pad 1.3.0 package-lock.json
NPM kept-lib 4.17.21 package-lock.json
NPM old-lib 2.0.0 yarn.lock
PYPI ghost 9.9.9 uv.lock
PYPI lowscore 1.0.0 poetry.lock
PYPI requests 2.34.2 requirements.txt
EOT
)"
actual="$(field all '.packages[] | "\(.system) \(.name) \(.version) \(.file)"' | sort)"
[ "${actual}" = "${expected}" ] || fail "added set differs:
${actual}"
[ "$(field all .added_count)" = "9" ] || fail "added_count"
[ "$(field all .blocking_count)" = "2" ] || fail "blocking_count $(field all .blocking_count)"
[ "$(output all added-count)" = "9" ] || fail "added-count output"
[ "$(output all blocking-count)" = "2" ] || fail "blocking-count output"
[ "$(output all report-path)" = "${TMP}/all/report.md" ] || fail "report-path output"
pkg() { jq -r ".packages[] | select(.name == \"$2\") | $3" "${TMP}/$1/findings.json"; }
[ "$(pkg all evil-stream .malicious)" = "true" ] || fail "evil-stream malicious"
[ "$(pkg all evil-stream '.advisories | join(",")')" = "MAL-2024-0001,GHSA-xxxx-yyyy-zzzz" ] || fail "evil-stream advisories"
[ "$(pkg all evil-stream .blocking)" = "true" ] || fail "evil-stream blocking"
[ "$(pkg all lowscore .score)" = "2.1" ] || fail "lowscore score"
[ "$(pkg all lowscore .blocking)" = "true" ] || fail "lowscore blocking"
[ "$(pkg all old-lib .blocking)" = "false" ] || fail "old-lib must only warn"
[ "$(pkg all old-lib '.flags | join(",")')" = "stale" ] || fail "old-lib flags $(pkg all old-lib '.flags | join(",")')"
[ "$(pkg all old-lib .last_release)" = "2019-01-01T00:00:00Z" ] || fail "old-lib last_release"
[ "$(pkg all ghost '.flags | join(",")')" = "unknown" ] || fail "ghost flags"
[ "$(pkg all ghost .score)" = "null" ] || fail "ghost score null"
[ "$(pkg all serde '.flags | join(",")')" = "no-scorecard" ] || fail "serde flags $(pkg all serde '.flags | join(",")')"
[ "$(pkg all serde .blocking)" = "false" ] || fail "serde no scorecard must not block"
[ "$(pkg all requests .score)" = "8.2" ] || fail "requests score"
[ "$(pkg all requests .checks.Maintained)" = "10" ] || fail "requests Maintained"
[ "$(pkg all requests '.checks["Signed-Releases"]')" = "0" ] || fail "requests Signed-Releases"
[ "$(pkg all requests .repository)" = "github.com/psf/requests" ] || fail "requests repository"
[ "$(pkg all requests '.flags | length')" = "0" ] || fail "requests clean"
[ "$(pkg all evil-stream .line)" = "8" ] || fail "evil-stream line $(pkg all evil-stream .line)"
grep -q '^::error file=pnpm-lock.yaml,line=8,title=dependency-reputation::evil-stream@0.1.1 ' "${TMP}/all/log" || fail "malicious annotation"
grep -q '^::error file=poetry.lock,line=6,title=dependency-reputation::lowscore@1.0.0 ' "${TMP}/all/log" || fail "low score annotation"
grep -q '^::warning file=yarn.lock,line=8,title=dependency-reputation::old-lib@2.0.0 ' "${TMP}/all/log" || fail "stale annotation"
grep -q '^::warning file=uv.lock,line=8,title=dependency-reputation::ghost@9.9.9 ' "${TMP}/all/log" || fail "unknown annotation"
[ "$(grep -c '^::error ' "${TMP}/all/log")" = "2" ] || fail "exactly two errors"
grep -q '^<!-- dependency-reputation -->' "${TMP}/all/report.md" || fail "report marker"
grep -qF "| \`evil-stream\` | 0.1.1 |" "${TMP}/all/report.md" || fail "report row"
grep -q 'MAL-2024-0001' "${TMP}/all/report.md" || fail "report malicious id"
grep -q 'github.com/psf/requests' "${TMP}/all/report.md" || fail "report repository"
grep -q 'dependency-reputation' "${TMP}/all/summary" || fail "step summary"

echo "== advisory: gates off, malicious still warns, exit 0"
run advisory --base-sha "${BASE}" --min-scorecard 0 --fail-on-malicious false
[ "${rc}" -eq 0 ] || fail "advisory rc ${rc}: $(cat "${TMP}/advisory/log")"
[ "$(field advisory .blocking_count)" = "0" ] || fail "advisory blocking"
grep -q '^::warning file=pnpm-lock.yaml,line=8,title=dependency-reputation::evil-stream@0.1.1 ' "${TMP}/advisory/log" || fail "advisory malicious warning"
[ "$(pkg advisory lowscore '.flags | length')" = "0" ] || fail "min-scorecard 0 must not flag"

echo "== ecosystems filter"
run npm --base-sha "${BASE}" --ecosystems npm
[ "$(field npm '[.packages[].system] | unique | join(",")')" = "NPM" ] || fail "ecosystem filter"
[ "$(field npm .added_count)" = "4" ] || fail "npm added_count"

echo "== exclude globs: fixture-style paths are skipped"
run excl --base-sha "${BASE}" --exclude '**/poetry.lock,uv.*,*.sum'
[ "$(field excl '[.packages[].file] | unique | join(",")')" = "Cargo.lock,package-lock.json,pnpm-lock.yaml,requirements.txt,yarn.lock" ] || fail "exclude: $(field excl '[.packages[].file] | unique | join(",")')"

echo "== no base: nothing to diff, exit 0"
run nobase
[ "${rc}" -eq 0 ] || fail "nobase rc ${rc}"
[ "$(field nobase .added_count)" = "0" ] || fail "nobase added"
grep -q '^::notice title=dependency-reputation::' "${TMP}/nobase/log" || fail "nobase notice"

echo "== offline miss: package not in cache is reported, not fetched"
mkdir -p "${TMP}/emptycache"
set +e
( cd "${REPO}" && python3 -I "${SCRIPT}" --cache-dir "${TMP}/emptycache" --offline --now "${NOW}" --base-sha "${BASE}" \
    --ecosystems cargo --output "${TMP}/miss.json" --report "${TMP}/miss.md" ) > "${TMP}/miss.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "miss rc ${rc}: $(cat "${TMP}/miss.log")"
[ "$(jq -r '.packages[0].flags | join(",")' "${TMP}/miss.json")" = "uncached" ] || fail "miss flags"

echo "== cache path confinement: a traversal version string never reads or writes outside cache-dir"
REPO2="${TMP}/repo2"
mkdir -p "${REPO2}" "${TMP}/cache2"
git -C "${REPO2}" init -q -b main
git -C "${REPO2}" config user.email t@example.com
git -C "${REPO2}" config user.name t
printf 'urllib3==2.8.0\n' > "${REPO2}/requirements.txt"
git -C "${REPO2}" add -A && git -C "${REPO2}" commit -q -m base
BASE2="$(git -C "${REPO2}" rev-parse HEAD)"
printf 'urllib3==2.8.0\npwn==/../../outside\n' > "${REPO2}/requirements.txt"
git -C "${REPO2}" add -A && git -C "${REPO2}" commit -q -m head
# The online path would mkdir the "pwn@" component before writing; seed it so
# the read side shows the same escape.
mkdir -p "${TMP}/cache2/PYPI/pwn@"
jq -n '{missing: true}' > "${TMP}/cache2/outside.json"
set +e
( cd "${REPO2}" && python3 -I "${SCRIPT}" --cache-dir "${TMP}/cache2" --offline --now "${NOW}" --base-sha "${BASE2}" \
    --output "${TMP}/trav.json" --report "${TMP}/trav.md" ) > "${TMP}/trav.log" 2>&1
rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "traversal rc ${rc}: $(cat "${TMP}/trav.log")"
[ "$(jq -r '.packages[0].flags | join(",")' "${TMP}/trav.json")" = "uncached" ] || fail "traversal version must not resolve outside the cache: $(jq -c '.packages[0]' "${TMP}/trav.json")"

echo "== usage errors exit 2"
run badeco --base-sha "${BASE}" --ecosystems npm,maven
[ "${rc}" -eq 2 ] || fail "bad ecosystem rc ${rc}"
grep -q '^::error title=dependency-reputation::' "${TMP}/badeco/log" || fail "bad ecosystem annotation"

echo "all dependency-reputation checks passed"
