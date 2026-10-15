#!/usr/bin/env bash
# End-of-life check (issue #230) against recorded endoflife.date responses
# (fixtures/api, fetched 2026-10-15) with the date fixed at 2026-10-15:
#   python 3.8 (.python-version)         end of life 2024-10-07  -> eol
#   go 1.25 (.tool-versions)             end of life 2026-08-19  -> eol
#   postgresql 14 (db/Dockerfile)        end of life 2026-11-12  -> warn (28 days)
#   python 3.12, nodejs 22 (x2), go 1.26                          -> ok
# plus the explicit products input, production false, and a fail-open run
# where the API is unreachable but the cache holds the last response. The issue
# step runs twice against a fake gh: the first run opens one issue per
# end-of-life cycle, the second updates them instead of opening duplicates.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EOL="${HERE}/../../.github/actions/eol-check/eol.py"
WORK="$(mktemp -d)"
trap 'find "${WORK}" -delete' EXIT
API="file://${HERE}/fixtures/api/{}.json"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
run() { python3 -I "${EOL}" --root "${HERE}/fixtures/repo" --out "${WORK}/report.json" --today 2026-10-15 "$@" 2>"${WORK}/stderr"; }
status_of() { jq -r '[.[] | "\(.product):\(.cycle):\(.status)\(if .severity != "" then ":" + .severity else "" end)"] | sort | join(" ")' "${WORK}/report.json"; }

run --api "${API}" --cache "${WORK}/cache" > "${WORK}/out"
check "detection and classification" "$(status_of)" \
  "go:1.25:eol:high go:1.26:ok nodejs:22:ok nodejs:22:ok postgresql:14:warn python:3.12:ok python:3.8:eol:high"
check "counts" "$(tr '\n' ' ' < "${WORK}/out")" "eol-count=2 warn-count=1 unknown-count=0 "
check "annotation on the Dockerfile" "$(grep -c '::warning file=[^,]*db/Dockerfile,title=eol-check::postgresql 14' "${WORK}/stderr")" "1"

run --api "${API}" --production false --products python:3.11 > "${WORK}/out"
check "explicit products win and production false is medium" "$(status_of | tr ' ' '\n' | grep -c '^python:3.11:ok$')/$(status_of | grep -o 'go:1.25:eol:[a-z]*')/$(status_of | grep -c 'python:3.8')" \
  "1/go:1.25:eol:medium/0"

run --api "file://${WORK}/nowhere/{}.json" --cache "${WORK}/cache" > "${WORK}/out"
check "unreachable API falls back to the cache" "$(tr '\n' ' ' < "${WORK}/out")/$(grep -c 'using the cached response' "${WORK}/stderr")" \
  "eol-count=2 warn-count=1 unknown-count=0 /4"

run --api "file://${WORK}/nowhere/{}.json" --cache "${WORK}/empty" > "${WORK}/out"
check "unreachable API with no cache fails open" "$(tr '\n' ' ' < "${WORK}/out")" "eol-count=0 warn-count=0 unknown-count=7 "

run --api "${API}" > /dev/null
echo '[]' > "${WORK}/issues.json"
issues() { PATH="${HERE}/fake-gh:${PATH}" FAKE_GH_STATE="${WORK}/issues.json" FAKE_GH_LOG="${WORK}/gh.log" REPO=o/r \
  REPORT="${WORK}/report.json" RUN_URL=https://example.invalid/run bash "${HERE}/../../.github/actions/eol-check/issues.sh" > /dev/null; }
issues
check "first run opens one issue per end-of-life cycle" "$(grep '^create' "${WORK}/gh.log" | sort | tr '\n' ';')" \
  "create End of life: go 1.25 [security-finding,sla:high,end-of-life];create End of life: python 3.8 [security-finding,sla:high,end-of-life];"
: > "${WORK}/gh.log"
issues
check "second run updates instead of duplicating" "$(grep -c '^create' "${WORK}/gh.log" || true)/$(grep -c '^edit' "${WORK}/gh.log")" "0/2"

exit "${fail}"
