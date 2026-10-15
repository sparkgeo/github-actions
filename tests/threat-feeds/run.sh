#!/usr/bin/env bash
# Checks normalize.py against trimmed real feed samples. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORM="${HERE}/../../.github/actions/threat-feeds/normalize.py"
FIX="${HERE}/fixtures"
NOW="2026-10-07T00:00:00Z"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

norm() {  # <feed> <input> [extra args]; sets rc, writes $TMP/<feed>.json
  local feed="$1" input="$2"; shift 2
  set +e
  python3 -I "${NORM}" --feed "${feed}" --input "${input}" --output "${TMP}/${feed}.json" --now "${NOW}" "$@" > "${TMP}/log" 2>&1
  rc=$?
  set -e
}
field() { jq -r "$2" "${TMP}/$1.json"; }

echo "== kev: cve entries, no expiry"
norm kev "${FIX}/kev.json"
[ "${rc}" -eq 0 ] || fail "kev rc ${rc}: $(cat "${TMP}/log")"
[ "$(field kev .feed)" = "kev" ] || fail "kev feed name"
[ "$(field kev .count)" = "3" ] || fail "kev count"
[ "$(field kev '[.entries[].type] | unique | join(",")')" = "cve" ] || fail "kev types"
[ "$(field kev '.entries[0].value')" = "CVE-2026-88779" ] || fail "kev first value"
[ "$(field kev '.entries[0] | has("expires_at")')" = "false" ] || fail "kev must not expire"
[ "$(field kev '.entries[0].meta.due_date')" = "2026-10-07" ] || fail "kev meta.due_date"
[ "$(field kev '.fetched_at')" = "${NOW}" ] || fail "kev fetched_at"
[ "$(field kev '.dropped_count')" = "0" ] || fail "kev dropped_count"

echo "== epss: scores kept as meta"
norm epss "${FIX}/epss.csv"
[ "${rc}" -eq 0 ] || fail "epss rc ${rc}: $(cat "${TMP}/log")"
[ "$(field epss .count)" = "5" ] || fail "epss count"
[ "$(field epss '.entries[] | select(.value == "CVE-2021-44228") | .meta.epss')" = "0.97565" ] || fail "epss score"
[ "$(field epss '.entries[] | select(.value == "CVE-2021-44228") | .meta.percentile')" = "0.99991" ] || fail "epss percentile"
[ "$(field epss '.meta.score_date')" = "2026-10-07T12:00:27Z" ] || fail "epss score_date in envelope"

echo "== threatfox: ip:port split, hashes skipped, 90-day domain expiry"
norm threatfox "${FIX}/threatfox.json"
[ "${rc}" -eq 0 ] || fail "threatfox rc ${rc}: $(cat "${TMP}/log")"
[ "$(field threatfox .count)" = "3" ] || fail "threatfox count $(field threatfox .count)"
[ "$(field threatfox .dropped_count)" = "1" ] || fail "threatfox dropped_count"
[ "$(field threatfox .skipped_count)" = "1" ] || fail "threatfox skipped_count"
[ "$(field threatfox '[.entries[] | .type + ":" + .value] | sort | join(" ")')" = "domain:evil.example.com ip:203.0.113.10 url:http://198.51.100.7/loader.bin" ] || fail "threatfox entries"
[ "$(field threatfox '.entries[] | select(.type == "ip") | .meta.port')" = "4444" ] || fail "threatfox ip port"
[ "$(field threatfox '.entries[] | select(.type == "ip") | .confidence')" = "75" ] || fail "threatfox confidence"
[ "$(field threatfox '.entries[] | select(.type == "ip") | .expires_at')" = "2026-11-05T09:00:00Z" ] || fail "ip expiry = last_seen + 30 d"
[ "$(field threatfox '.entries[] | select(.type == "domain") | .expires_at')" = "2027-01-04T12:00:00Z" ] || fail "domain expiry = first_seen + 90 d"
[ "$(field threatfox '.entries[] | select(.type == "url") | .expires_at')" = "2026-12-04T00:00:00Z" ] || fail "url expiry = first_seen + 60 d"

echo "== feodo: 30-day ip expiry from last_online, falls back to first_seen"
norm feodo "${FIX}/feodo.json"
[ "${rc}" -eq 0 ] || fail "feodo rc ${rc}: $(cat "${TMP}/log")"
[ "$(field feodo .count)" = "2" ] || fail "feodo count"
[ "$(field feodo .dropped_count)" = "1" ] || fail "feodo dropped_count"
[ "$(field feodo '[.entries[].value] | sort | join(" ")')" = "192.0.2.50 192.0.2.51" ] || fail "feodo entries"
[ "$(field feodo '.entries[] | select(.value == "192.0.2.50") | .confidence')" = "100" ] || fail "feodo online confidence"
[ "$(field feodo '.entries[] | select(.value == "192.0.2.51") | .confidence')" = "50" ] || fail "feodo offline confidence"
[ "$(field feodo '.entries[] | select(.value == "192.0.2.50") | .meta.malware')" = "QakBot" ] || fail "feodo malware"

echo "== urlhaus: 60-day url expiry, empty last_online"
norm urlhaus "${FIX}/urlhaus.csv"
[ "${rc}" -eq 0 ] || fail "urlhaus rc ${rc}: $(cat "${TMP}/log")"
[ "$(field urlhaus .count)" = "3" ] || fail "urlhaus count"
[ "$(field urlhaus .dropped_count)" = "1" ] || fail "urlhaus dropped_count"
[ "$(field urlhaus '.entries[] | select(.value == "http://new.example.org/y.sh") | .expires_at')" = "2026-12-04T00:00:00Z" ] || fail "urlhaus expiry from dateadded"
[ "$(field urlhaus '.entries[0].meta.threat')" = "malware_download" ] || fail "urlhaus meta.threat"

echo "== drop check: count below half of previous snapshot fails"
norm threatfox "${FIX}/threatfox.json" --previous "${FIX}/previous/threatfox.json"
[ "${rc}" -eq 2 ] || fail "drop check: expected rc 2, got ${rc}"
grep -q "^::error title=threat-feeds threatfox::" "${TMP}/log" || fail "drop check: missing error annotation"

echo "== drop check: previous within tolerance passes"
jq '.count = 5' "${FIX}/previous/threatfox.json" > "${TMP}/prev.json"
norm threatfox "${FIX}/threatfox.json" --previous "${TMP}/prev.json"
[ "${rc}" -eq 0 ] || fail "drop tolerance: expected rc 0, got ${rc}"

echo "== garbage input fails"
norm kev "${FIX}/garbage.json"
[ "${rc}" -eq 1 ] || fail "garbage: expected rc 1, got ${rc}"

echo "== empty feed fails"
echo '{"vulnerabilities": []}' > "${TMP}/empty.json"
norm kev "${TMP}/empty.json"
[ "${rc}" -eq 1 ] || fail "empty: expected rc 1, got ${rc}"

echo "all threat-feeds checks passed"
