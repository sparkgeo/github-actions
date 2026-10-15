#!/usr/bin/env bash
# Checks report.py against recorded govulncheck JSON output for the fixture
# module (one reachable advisory, one imported-not-called, two module-only).
# Needs python3 and jq. The composite itself is exercised by the govulncheck
# job in ci.yml against tests/govulncheck/fixtures/module.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="${HERE}/../../.github/actions/govulncheck/report.py"
FIX="${HERE}/fixtures/govulncheck.jsonl"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> [args]; sets rc; writes $TMP/<name>.{log,out,summary,json}
  local name="$1"; shift
  : > "${TMP}/${name}.out"
  set +e
  GITHUB_OUTPUT="${TMP}/${name}.out" GITHUB_STEP_SUMMARY="${TMP}/${name}.summary" \
    python3 -I "${REPORT}" --input "${FIX}" --output "${TMP}/${name}.json" "$@" > "${TMP}/${name}.log" 2>&1
  rc=$?
  set -e
}
q() { jq -r "$2" "${TMP}/$1.json"; }
output() { grep "^$2=" "${TMP}/$1.out" | cut -d= -f2-; }

echo "== fail-on reachable: one reachable advisory fails the gate"
run gate --fail-on reachable --working-directory tests/govulncheck/fixtures/module
[ "${rc}" -eq 1 ] || fail "expected rc 1, got ${rc}: $(cat "${TMP}/gate.log")"
[ "$(q gate '.counts | "\(.reachable) \(.imported) \(.module)"')" = "1 1 2" ] || fail "counts $(q gate .counts)"
[ "$(q gate '.findings[0].id')" = "GO-2021-0113" ] && [ "$(q gate '.findings[0].level')" = "reachable" ] || fail "reachable first"
[ "$(q gate '.findings[0].calls[0] | "\(.caller) -> \(.vulnerable) \(.file):\(.line)"')" = "example.com/govulncheck-fixture.main -> golang.org/x/text/language.MustParse main.go:14" ] || fail "call site: $(q gate '.findings[0].calls')"
[ "$(q gate '.findings[0].fixed_version')" = "v0.3.7" ] || fail "fixed version"
[ "$(q gate '.findings[0].aliases | join(",")')" = "CVE-2021-38561,GHSA-ppp9-7jff-5vj2" ] || fail "aliases"
[ "$(q gate '.findings[] | select(.id == "GO-2022-1059") | "\(.level) \(.package)"')" = "imported golang.org/x/text/language" ] || fail "imported level keeps the package"
[ "$(q gate '[.findings[] | select(.level == "module") | .id] | join(",")')" = "GO-2026-5970,GO-2026-6629" ] || fail "module-only ids"
grep -q '^::error file=tests/govulncheck/fixtures/module/main.go,line=14,col=32,title=govulncheck GO-2021-0113::' "${TMP}/gate.log" || fail "inline error annotation: $(grep '::error' "${TMP}/gate.log")"
grep -q '^::notice title=govulncheck GO-2022-1059 (imported, not called)::' "${TMP}/gate.log" || fail "notice for the imported advisory"
! grep -q 'GO-2026-5970' <(grep -E '^::(error|notice)' "${TMP}/gate.log") || fail "module-only advisories must not annotate"
grep -q '^## govulncheck: 1 reachable, 1 imported but not called, 2 module-only' "${TMP}/gate.summary" || fail "summary heading: $(head -1 "${TMP}/gate.summary")"
grep -q '| \[GO-2021-0113\](https://pkg.go.dev/vuln/GO-2021-0113) CVE-2021-38561, GHSA-ppp9-7jff-5vj2 | \*\*reachable\*\* | golang.org/x/text | golang.org/x/text/language | v0.3.7 | example.com/govulncheck-fixture.main (main.go:14) |' "${TMP}/gate.summary" || fail "summary row: $(grep GO-2021-0113 "${TMP}/gate.summary")"
[ "$(output gate reachable-count)" = "1" ] && [ "$(output gate imported-count)" = "1" ] && [ "$(output gate module-count)" = "2" ] || fail "outputs: $(cat "${TMP}/gate.out")"

echo "== fail-on none: reported, job passes"
run advisory --fail-on none
[ "${rc}" -eq 0 ] || fail "expected rc 0, got ${rc}"
[ "$(output advisory reachable-count)" = "1" ] || fail "counts unchanged in advisory mode"

echo "== empty stream: nothing found, passes"
: > "${TMP}/empty.json"
set +e; python3 -I "${REPORT}" --input "${TMP}/empty.json" --output "${TMP}/e.json" > "${TMP}/e.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}"
[ "$(jq -r '.counts.reachable' "${TMP}/e.json")" = "0" ] || fail "empty counts"
grep -q '^## govulncheck: 0 reachable, 0 imported but not called, 0 module-only' "${TMP}/e.log" || fail "empty summary"

echo "all govulncheck checks passed"
