#!/usr/bin/env bash
# Plans every listed stack of one checkout and writes plan JSON per stack
# (issue #89). Usage: plan.sh <checkout-root> <stacks.txt> <plans-dir>
# For each stack: tofu init, tofu plan -lock=false, tofu show -json. A stack
# missing from the checkout (new on the head ref) is skipped with a notice.
set -euo pipefail

ROOT="${1:?checkout root}"; STACKS="${2:?stack list}"; PLANS="${3:?plans dir}"
TOFU="${TOFU:-tofu}"
while IFS= read -r stack; do
  [ -n "${stack}" ] || continue
  dir="${ROOT}/${stack}"
  if [ ! -d "${dir}" ]; then
    echo "::notice title=infracost::${stack} does not exist in ${ROOT}; treated as new"
    continue
  fi
  echo "::group::plan ${stack}"
  out="${PLANS:?}/${stack:?}"
  mkdir -p "${out}"
  ( cd "${dir}" \
    && "${TOFU}" init -input=false -no-color > /dev/null \
    && "${TOFU}" plan -input=false -lock=false -no-color -out="${out}/plan.bin" > /dev/null \
    && "${TOFU}" show -json "${out}/plan.bin" > "${out}/plan.json" )
  # The binary plan can hold sensitive values; only the JSON leaves the step.
  rm -f "${out:?}/plan.bin"
  echo "::endgroup::"
done < "${STACKS}"
