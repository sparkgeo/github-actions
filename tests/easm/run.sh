#!/usr/bin/env bash
# Checks reconcile.py (scope validation and reconciliation) against recorded
# discovery outputs. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC="${HERE}/../../.github/actions/easm/reconcile.py"
FIX="${HERE}/fixtures"
NOW="2026-10-07T03:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { jq -r "$1" "${TMP}/out/findings.json"; }

echo "== check-scope: good scope passes, bad scope lists every problem"
python3 -I "${REC}" check-scope --scope "${FIX}/scope.json" || fail "good scope rejected"
set +e; python3 -I "${REC}" check-scope --scope "${FIX}/scope-bad.json" > "${TMP}/scope.log" 2>&1; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "bad scope rc ${rc}"
for want in "domain example.com has no authorisation" "is not a hostname" "cidr 203.0.113.0/24 needs owner and authorisation" "known host www.example.com has no owner" "known host www.other.test is outside every scoped domain"; do
  grep -qF "::error title=easm scope::" "${TMP}/scope.log" && grep -qF "${want}" "${TMP}/scope.log" || fail "bad scope: missing '${want}': $(cat "${TMP}/scope.log")"
done
python3 -I "${REC}" check-scope --scope "${HERE}/../../easm/scope.json" || fail "the committed scope must pass its own check"

echo "== reconcile with the register"
python3 -I "${REC}" reconcile --scope "${FIX}/scope.json" --register "${FIX}/assets.json" --dnsx "${FIX}/dnsx.jsonl" \
  --httpx "${FIX}/httpx.jsonl" --naabu "${FIX}/naabu.jsonl" --nuclei "${FIX}/nuclei.jsonl" --dnstwist "${FIX}/dnstwist.json" \
  --now "${NOW}" --out-dir "${TMP}/out" > "${TMP}/log"
# unknown: staging-geoserver (in scope, not known) and portal.client.example (scoped client domain, not known); excluded host never appears
[ "$(q '[.findings[] | select(.kind == "unknown-asset") | .host] | join(",")')" = "portal.client.example,staging-geoserver.example.com" ] || fail "unknown assets: $(q '[.findings[] | select(.kind == "unknown-asset") | .host]')"
[ "$(q '.findings[] | select(.kind == "unknown-asset" and .host == "staging-geoserver.example.com") | .ports | join(",")')" = "5432,8080" ] || fail "unknown asset ports merge httpx and naabu"
# known: www (scope), api (register route53 record, trailing dot stripped), tiles (register exposure=public)
[ "$(q '.expected_public')" = "4" ] || fail "expected_public $(q '.expected_public')"
grep -qF '| api.example.com | team-api | sparkgeo/geo-api aws_route53_record.api |' "${TMP}/out/public-assets.md" || fail "api owner from register: $(cat "${TMP}/out/public-assets.md")"
grep -qF '| tiles.example.com | team-geo | sparkgeo/geo-api aws_cloudfront_distribution.tiles (exposure=public) |' "${TMP}/out/public-assets.md" || fail "tiles via exposure=public"
grep -qF '| www.example.com | team-platform | scope.known_hosts | 443 |' "${TMP}/out/public-assets.md" || fail "www from scope"
grep -qF '| staging-geoserver.example.com | (unknown) | discovered | 5432,8080 |' "${TMP}/out/public-assets.md" || fail "unknown host listed for attestation"
! grep -q 'donotscan' "${TMP}/out/public-assets.md" || fail "excluded host must not be listed"
# retired: old.example.com is expected but resolves to nothing
[ "$(q '[.findings[] | select(.kind == "retired-candidate") | .host] | join(",")')" = "old.example.com" ] || fail "retired"
grep -qF '| old.example.com | team-platform | scope.known_hosts |' "${TMP}/out/retired-candidates.md" || fail "retired-candidates.md"
# takeover: dangling CNAME with no A
[ "$(q '.findings[] | select(.kind == "takeover-candidate") | .host')" = "dangling.example.com" ] || fail "takeover candidate"
# nuclei: passthrough, excluded host dropped
[ "$(q '[.findings[] | select(.kind == "nuclei") | .template] | join(",")')" = "geoserver-default-login,tls-version" ] || fail "nuclei findings: $(q '[.findings[] | select(.kind == "nuclei") | .template]')"
[ "$(q '.findings[] | select(.template == "geoserver-default-login") | .severity')" = "high" ] || fail "nuclei severity"
# lookalike: registered ones only, original excluded
[ "$(q '[.findings[] | select(.kind == "lookalike-domain") | .host] | join(",")')" = "examp1e.com,examplea.com" ] || fail "lookalikes: $(q '[.findings[] | select(.kind == "lookalike-domain") | .host]')"
# ordering: severity then kind
[ "$(q '.findings[0].kind')" = "nuclei" ] && [ "$(q '.findings[0].severity')" = "high" ] || fail "first finding should be a high nuclei finding (kind order within high: nuclei < takeover < unknown)"
[ "$(q '.counts | "\(.["unknown-asset"]) \(.["takeover-candidate"]) \(.nuclei) \(.["lookalike-domain"]) \(.["retired-candidate"])"')" = "2 1 2 2 1" ] || fail "counts $(q '.counts')"
[ "$(q '.live_hosts')" = "5" ] || fail "live hosts $(q '.live_hosts')"
[ "$(q '.inventory_review')" = "false" ] || fail "2 unknown is under the threshold of 3"
grep -q '^## External attack surface: 5 live hosts, 2 unknown' "${TMP}/out/summary.md" || fail "summary heading: $(head -1 "${TMP}/out/summary.md")"
grep -q 'staging-geoserver.example.com' "${TMP}/out/unknown-assets.md" || fail "unknown-assets.md"

echo "== threshold: --unknown-threshold 1 flags an inventory review"
python3 -I "${REC}" reconcile --scope "${FIX}/scope.json" --register "${FIX}/assets.json" --dnsx "${FIX}/dnsx.jsonl" \
  --httpx "${FIX}/httpx.jsonl" --unknown-threshold 1 --now "${NOW}" --out-dir "${TMP}/out" > /dev/null
[ "$(q '.inventory_review')" = "true" ] || fail "threshold"
grep -q 'inventory review' "${TMP}/out/summary.md" || fail "summary flags the review"

echo "== without the register: only scope.known_hosts are expected"
python3 -I "${REC}" reconcile --scope "${FIX}/scope.json" --dnsx "${FIX}/dnsx.jsonl" --httpx "${FIX}/httpx.jsonl" \
  --now "${NOW}" --out-dir "${TMP}/out" > /dev/null
[ "$(q '.expected_public')" = "2" ] || fail "expected without register"
[ "$(q '[.findings[] | select(.kind == "unknown-asset") | .host] | join(",")')" = "api.example.com,portal.client.example,staging-geoserver.example.com,tiles.example.com" ] || fail "register hosts become unknown without the register"

echo "== missing inputs are tolerated"
python3 -I "${REC}" reconcile --scope "${FIX}/scope.json" --now "${NOW}" --out-dir "${TMP}/out" > /dev/null
[ "$(q '.findings | length')" = "0" ] && [ "$(q '.live_hosts')" = "0" ] || fail "empty run"

echo "all easm checks passed"
