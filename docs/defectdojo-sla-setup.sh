#!/usr/bin/env bash
# One-time DefectDojo SLA setup for Sparkgeo products (issue #185), from the
# docs/gate-policy.md rows: critical 48 h production / 7 days non-production,
# high 7 / 30 days, medium 30 / 90 days, low 90 days. DefectDojo counts SLA
# in whole days and has no secret category: secrets are hard-blocked in CI
# and rotated at once, so they never wait in the queue.
#
# Usage: DD_URL=https://defectdojo.example DD_TOKEN=… \
#          docs/defectdojo-sla-setup.sh production|non-production PRODUCT...
# Creates or updates the two SLA configurations by name, then assigns the
# named one to each product. Re-running is safe.
set -euo pipefail

tier="${1:?production or non-production}"; shift
[ "$#" -gt 0 ] || { echo "name at least one product" >&2; exit 2; }
: "${DD_URL:?}" "${DD_TOKEN:?}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
printf 'Authorization: Token %s\n' "${DD_TOKEN}" > "${TMP}/auth"
api() {  # <method> <path> [json body]
  curl -sS --fail-with-body -X "$1" -H @"${TMP}/auth" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "${DD_URL%/}/api/v2/$2"
}

upsert() {  # <name> <critical> <high> <medium> <low>; prints the id
  local body id
  body="$(jq -nc --arg n "$1" --argjson c "$2" --argjson h "$3" --argjson m "$4" --argjson l "$5" \
    '{name: $n, description: "From docs/gate-policy.md (sparkgeo/github-actions)",
      critical: $c, high: $h, medium: $m, low: $l,
      enforce_critical: true, enforce_high: true, enforce_medium: true, enforce_low: true}')"
  id="$(api GET "sla_configurations/?limit=1000" | jq -r --arg n "$1" '.results[] | select(.name == $n) | .id' | head -1)"
  if [ -n "${id}" ]; then api PATCH "sla_configurations/${id}/" "${body}" > /dev/null; else
    id="$(api POST sla_configurations/ "${body}" | jq -r .id)"; fi
  echo "${id}"
}

prod="$(upsert "Sparkgeo production" 2 7 30 90)"
nonprod="$(upsert "Sparkgeo non-production" 7 30 90 90)"
case "${tier}" in
  production) sla="${prod}" ;;
  non-production) sla="${nonprod}" ;;
  *) echo "tier must be production or non-production" >&2; exit 2 ;;
esac
for p in "$@"; do
  id="$(api GET "products/?name=$(jq -rn --arg p "${p}" '$p|@uri')" | jq -r '.results[0].id // empty')"
  [ -n "${id}" ] || { echo "product '${p}' not found (import once first)" >&2; exit 1; }
  api PATCH "products/${id}/" "$(jq -nc --argjson s "${sla}" '{sla_configuration: $s}')" > /dev/null
  echo "${p}: SLA configuration ${sla} (${tier})"
done
