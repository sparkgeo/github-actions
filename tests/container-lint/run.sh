#!/usr/bin/env bash
# Runs the hadolint composite's digest-check script against fixture
# Dockerfiles and asserts the exit code and the number of violations.
# Executed in CI by the container-lint job and locally with:
#   bash tests/container-lint/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHECK="$ROOT/.github/actions/hadolint/digest-check.sh"
[ -f "$CHECK" ] || { echo "FAIL: $CHECK missing"; exit 1; }

fails=0
# files | expected rc | expected violation count
while IFS='|' read -r files want_rc want_count; do
  log="$(mktemp)"; out="$(mktemp)"; export GITHUB_OUTPUT="$out"; : > "$out"
  # shellcheck disable=SC2086
  bash "$CHECK" $files > "$log" 2>&1; rc=$?
  got=$(grep -c '^::error file=' "$log")
  reported="$(grep '^unpinned-count=' "$out" | cut -d= -f2-)"
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want_count" ] && [ "$reported" = "$want_count" ]; then
    echo "ok   $files -> rc=$rc violations=$got"
  else
    echo "FAIL $files -> rc=$rc (want $want_rc) violations=$got reported=$reported (want $want_count)"; sed 's/^/     /' "$log"; fails=$((fails+1))
  fi
done <<CASES
$HERE/fixtures/good/Dockerfile|0|0
$HERE/fixtures/bad/Dockerfile|1|3
$HERE/fixtures/good/Dockerfile $HERE/fixtures/bad/Dockerfile|1|3
CASES
echo "$fails failure(s)"
exit "$fails"
