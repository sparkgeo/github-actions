#!/usr/bin/env bash
# Normalises the recorded KEV, advisories and Vulnrichment samples, then checks
# match.py against the fixture product list and register. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/../.."
NORM="${ROOT}/.github/actions/threat-feeds/normalize.py"
MATCH="${ROOT}/.github/actions/kev-trigger/match.py"
FEEDFIX="${ROOT}/tests/threat-feeds/fixtures"
FIX="${HERE}/fixtures"
NOW="2026-10-07T00:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { jq -r "$1" "${TMP}/matches.json"; }

mkdir -p "${TMP}/feeds"
python3 -I "${NORM}" --feed kev --input "${FEEDFIX}/kev.json" --output "${TMP}/feeds/kev.json" --now "${NOW}" > /dev/null
python3 -I "${NORM}" --feed advisories --input "${FEEDFIX}/advisories.xml" --output "${TMP}/feeds/advisories.json" --now "${NOW}" > /dev/null
python3 -I "${NORM}" --feed vulnrichment --input "${FEEDFIX}/vulnrichment.json" --output "${TMP}/feeds/vulnrichment.json" --now "${NOW}" > /dev/null

echo "== with register: KEV and advisory matches, exposure and owners from the register"
python3 -I "${MATCH}" --feeds-dir "${TMP}/feeds" --products "${FIX}/products.json" --register "${FIX}/assets.json" \
  --window-days 7 --now "${NOW}" --output "${TMP}/matches.json" > /dev/null
[ "$(q '.matches | length')" = "2" ] || fail "expected 2 matches, got $(q '.matches | length'): $(q '[.matches[].id] | join(",")')"
# KEV CVE-2026-88779 (Citrix NetScaler, added 2026-10-04) matches the NetScaler product
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .product')" = "Citrix NetScaler" ] || fail "netscaler kev match"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .exposure')" = "public" ] || fail "exposure from the register (geo-api has a public record)"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .owners | join(",")')" = "team-api,team-edge" ] || fail "owners merge product owner and register owners"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .sla')" = "critical" ] || fail "kev sla critical"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .validate_by')" = "2026-10-10T00:00:00Z" ] || fail "72 h deadline"
# forensic triage: public exposure and KEV forensicTriage=Yes (Vulnrichment says technical impact partial)
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .forensic_triage')" = "true" ] || fail "forensic triage on a public asset with KEV forensicTriage yes"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .ssvc.automatable')" = "yes" ] || fail "ssvc from vulnrichment"
# advisories: the NetScaler KEV alert names NetScaler in its title? no; the GeoServer advisory matches GeoServer; the old ICS one is outside the window
[ "$(q '[.matches[] | select(.kind == "advisory")] | length')" = "1" ] || fail "one advisory match"
[ "$(q '.matches[] | select(.kind == "advisory") | .product')" = "GeoServer" ] || fail "geoserver advisory"
[ "$(q '.matches[] | select(.kind == "advisory") | .cves | join(",")')" = "CVE-2026-55555" ] || fail "advisory cve extraction"
[ "$(q '.matches[] | select(.kind == "advisory") | .exposure')" = "public" ] || fail "exposure falls back to the product entry when the register has no public record"
[ "$(q '.matches[] | select(.kind == "advisory") | .owners | join(",")')" = "team-old" ] || fail "owners from the register only"
[ "$(q '.matches[] | select(.kind == "advisory") | .forensic_triage')" = "false" ] || fail "no forensic triage on an advisory"
# the KEV catalog alert advisory names both products? it names NetScaler in the description, not the title: no match by design
# unmatched: Zammad (2) are new and match nothing
[ "$(q '.unmatched_kev | length')" = "2" ] || fail "unmatched kev count $(q '.unmatched_kev | length')"
[ "$(q '[.matches[].kind] | sort | join(",")')" = "advisory,kev" ] || fail "kinds"

echo "== without register: exposure and owner from the product entry"
python3 -I "${MATCH}" --feeds-dir "${TMP}/feeds" --products "${FIX}/products.json" \
  --window-days 7 --now "${NOW}" --output "${TMP}/matches.json" > /dev/null
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .exposure')" = "internal" ] || fail "exposure from product entry"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .forensic_triage')" = "false" ] || fail "no forensic triage when internal"
[ "$(q '.matches[] | select(.id == "CVE-2026-88779") | .owners | join(",")')" = "team-edge" ] || fail "owner from product entry"

echo "== window: one day excludes the 2026-10-02 KEV entries and the 09-30 advisory"
python3 -I "${MATCH}" --feeds-dir "${TMP}/feeds" --products "${FIX}/products.json" \
  --window-days 1 --now "2026-10-05T00:00:00Z" --output "${TMP}/matches.json" > /dev/null
[ "$(q '[.matches[].id] | join(",")')" = "CVE-2026-88779" ] || fail "window filter: $(q '[.matches[].id] | join(",")')"

echo "== missing feeds are tolerated"
mkdir -p "${TMP}/onlykev" && cp "${TMP}/feeds/kev.json" "${TMP}/onlykev/"
python3 -I "${MATCH}" --feeds-dir "${TMP}/onlykev" --products "${FIX}/products.json" \
  --window-days 7 --now "${NOW}" --output "${TMP}/matches.json" > /dev/null
[ "$(q '.matches | length')" = "1" ] || fail "kev only"
[ "$(q '.matches[0].ssvc')" = "null" ] || fail "ssvc null without vulnrichment"

echo "all kev-trigger checks passed"
