#!/usr/bin/env bash
# Writes an Infracost config file to stdout from a stack list (issue #89).
# Usage: mkconfig.sh <stacks.txt> <plans-dir> [usage-file]
# Each stack with <plans-dir>/<stack>/plan.json becomes a project; stacks
# without a plan are skipped with a notice (a stack that does not exist on the
# base ref, for example). Exits 1 when no stack has a plan.
set -euo pipefail

STACKS="$1"; PLANS="$2"; USAGE="${3:-}"
echo 'version: "0.1"'
echo 'projects:'
count=0
while IFS= read -r stack; do
  [ -n "${stack}" ] || continue
  plan="${PLANS}/${stack}/plan.json"
  if [ ! -f "${plan}" ]; then
    echo "::notice title=infracost::${stack} has no plan under ${PLANS}; skipped" >&2
    continue
  fi
  echo "  - path: ${plan}"
  echo "    name: ${stack}"
  [ -n "${USAGE}" ] && echo "    usage_file: ${USAGE}"
  count=$((count + 1))
done < "${STACKS}"
if [ "${count}" -eq 0 ]; then
  echo "::error title=infracost::no plan JSON found for any stack under ${PLANS}" >&2
  exit 1
fi
