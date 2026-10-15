#!/usr/bin/env bash
# Checks the privacy review gate's gate.py against fixture PRs, reviews, team
# members, changed-file lists, a ropa.yml and privado reports: the three
# triggers, the three requirements, stale and revoked approvals, non-member
# approvals, the reviewer fallback and the untriggered case. Standard
# library only; needs jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
GATE="${ROOT}/.github/actions/privacy-review-gate/gate.py"
FIX="${HERE}/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <pr> <reviews> <changed> [args]; sets rc; runs inside fixtures so IaC files resolve
  : > "${TMP}/$1.out"
  set +e
  (cd "${FIX}" && GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${GATE}" --pr "$2" --reviews "$3" --changed "$4" --ropa ropa.yml --owner sparkgeo/privacy \
    --comment "${TMP}/$1.md" --output "${TMP}/$1.json" "${@:5}") > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
j() { jq -r "$2" "${TMP}/$1.json"; }

echo "== not triggered: plain change, empty PIA section"
run plain pr-plain.json reviews-approved.json changed-plain.txt --members members.json
[ "${rc}" -eq 0 ] || fail "plain rc ${rc}: $(cat "${TMP}/plain.log")"
[ "$(j plain .triggered)" = "false" ] || fail "plain must not trigger: $(jq -c .triggers "${TMP}/plain.json")"
grep -q '^## Privacy review gate: not required' "${TMP}/plain.summary" || fail "not-required heading"
[ "$(grep '^triggered=' "${TMP}/plain.out" | cut -d= -f2)" = "false" ] || fail "triggered output"

echo "== triggered by a models path, complete: label, approval on head by a team member, PIA link"
run ok pr-complete.json reviews-approved.json changed-models.txt --members members.json
[ "${rc}" -eq 0 ] || fail "ok rc ${rc}: $(cat "${TMP}/ok.log")"
{ [ "$(j ok .triggered)" = "true" ] && [ "$(j ok '.approvals | join(",")')" = "privacy-lead" ]; } || fail "ok approvals: $(jq -c . "${TMP}/ok.json")"
[ "$(j ok .link)" = "docs/pia/user-locations.md" ] || fail "pia link"
grep -q 'src/models/user.py.*matches \*\*/models/\*\*' "${TMP}/ok.summary" || fail "path reason"
grep -q 'section is filled in' "${TMP}/ok.summary" || fail "self-declared trigger"
head -1 "${TMP}/ok.md" | grep -q '^<!-- privacy-review-gate -->$' || fail "comment marker"

echo "== triggered, missing everything: no label, approval from a non-member only, no link"
jq '.labels = [] | .body = "## Summary\n\nAdd phone to the users table.\n"' "${FIX}/pr-complete.json" > "${FIX}/pr-missing.json"
jq '[.[] | select(.user.login == "random-dev")]' "${FIX}/reviews-approved.json" > "${FIX}/reviews-nonmember.json"
run miss pr-missing.json reviews-nonmember.json changed-models.txt --members members.json
rm -f "${FIX}/pr-missing.json" "${FIX}/reviews-nonmember.json"
[ "${rc}" -eq 1 ] || fail "missing must fail"
[ "$(j miss '.missing | length')" = "3" ] || fail "three missing: $(jq -c .missing "${TMP}/miss.json")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^::error title=privacy-review::privacy review incomplete: label `privacy-review`; an approving review on the current head from a member of `sparkgeo/privacy`; a PIA link in the PR body matching `docs/pia/`' "${TMP}/miss.log" || fail "error line: $(grep '::error' "${TMP}/miss.log")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q 'Fill in `docs/pia-template.md`' "${TMP}/miss.summary" || fail "template pointer"

echo "== stale approval (earlier commit) and revoked approval (changes requested later) do not count"
run stale pr-complete.json reviews-stale.json changed-models.txt --members members.json
{ [ "${rc}" -eq 1 ] && grep -q 'approval by privacy-lead is for an earlier commit' "${TMP}/stale.log"; } || fail "stale approval"
run revoked pr-complete.json reviews-revoked.json changed-models.txt --members members.json
{ [ "${rc}" -eq 1 ] && [ "$(j revoked '.approvals | length')" = "0" ]; } || fail "revoked approval"

echo "== reviewer fallback when the team cannot be read; no list at all is an explicit gap"
run fallback pr-complete.json reviews-approved.json changed-models.txt --reviewers privacy-lead,dpo
[ "${rc}" -eq 0 ] || fail "fallback rc ${rc}"
run nolist pr-complete.json reviews-approved.json changed-models.txt
{ [ "${rc}" -eq 1 ] && grep -q 'the token cannot read the team' "${TMP}/nolist.log"; } || fail "no reviewer list"

echo "== triggered by an IaC file that defines a ropa.yml store; by a privado new flow; not by an unchanged report"
run iac pr-plain.json reviews-approved.json changed-iac.txt --members members.json
{ [ "$(j iac .triggered)" = "true" ] && grep -q 'defines store aws_rds_cluster.app from ropa.yml' "${TMP}/iac.summary"; } || fail "iac trigger: $(jq -c .hits "${TMP}/iac.json")"
run privado pr-plain.json reviews-approved.json changed-plain.txt --members members.json --privado privado-new.json
{ [ "$(j privado .triggered)" = "true" ] && [ "$(j privado '.privado_new | length')" = "3" ]; } || fail "privado trigger: $(jq -c .privado_new "${TMP}/privado.json")"
[ "${rc}" -eq 1 ] || fail "privado-triggered PR without label/link must fail"
run same pr-plain.json reviews-approved.json changed-plain.txt --members members.json --privado privado-same.json
[ "$(j same .triggered)" = "false" ] || fail "unchanged report must not trigger"

echo "== custom paths and pattern"
run custom pr-complete.json reviews-approved.json changed-plain.txt --members members.json --privacy-paths 'docs/**' --pia-link-pattern 'https://tracker.example/pia/'
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
{ [ "${rc}" -eq 1 ] && grep -q 'a PIA link in the PR body matching `https://tracker.example/pia/`' "${TMP}/custom.log"; } || fail "custom pattern"

echo "all privacy-review-gate checks passed"
