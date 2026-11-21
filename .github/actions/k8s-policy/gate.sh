#!/usr/bin/env bash
# Turns conftest JSON output into annotations, a job summary and step outputs.
# Exits 1 when any policy denied, or on warnings when FAIL_ON_WARN=true.
#
# Env: RESULTS (conftest -o json file), RENDER_DIR (prefix stripped from
# filenames to recover the chart/overlay path), FAIL_ON_WARN (true|false).
set -euo pipefail

: "${RESULTS:?}" "${RENDER_DIR:?}"
FAIL_ON_WARN="${FAIL_ON_WARN:-false}"
[ -f "${RESULTS}" ] || { echo "::error title=k8s-policy::results file not found: ${RESULTS}"; exit 2; }

# filename -> target: strip "<RENDER_DIR>/" and the "/helm.yaml" | "/kustomize.yaml" leaf.
rows() {  # <level> <key>
  jq -r --arg prefix "${RENDER_DIR%/}/" --arg level "$1" --arg key "$2" '
    .[] | (.filename | ltrimstr($prefix) | sub("/(helm|kustomize)\\.yaml$"; "")) as $target
    | .[$key][]? | [$target, $level, .msg] | @tsv' "${RESULTS}"
}

deny_count=0
warn_count=0
{
  echo "## K8s Policy (conftest)"
  echo
  echo "| Target | Result | Message |"
  echo "|---|---|---|"
} >> "${GITHUB_STEP_SUMMARY}"

while IFS=$'\t' read -r target level msg; do
  [ -n "${target}" ] || continue
  if [ "${level}" = "deny" ]; then
    deny_count=$((deny_count + 1))
    echo "::error title=k8s-policy ${target}::${msg}"
  else
    warn_count=$((warn_count + 1))
    echo "::warning title=k8s-policy ${target}::${msg}"
  fi
  echo "| ${target} | ${level} | ${msg//|/\\|} |" >> "${GITHUB_STEP_SUMMARY}"
done < <(rows deny failures; rows warn warnings)

# Targets with no findings still get a row so the summary shows what was checked.
jq -r --arg prefix "${RENDER_DIR%/}/" '
  .[] | select(((.failures // []) | length) == 0 and ((.warnings // []) | length) == 0)
  | (.filename | ltrimstr($prefix) | sub("/(helm|kustomize)\\.yaml$"; ""))
  | "| \(.) | pass | |"' "${RESULTS}" >> "${GITHUB_STEP_SUMMARY}"

{
  echo
  echo "Denied: ${deny_count} · Warnings: ${warn_count}"
} >> "${GITHUB_STEP_SUMMARY}"
{
  echo "deny-count=${deny_count}"
  echo "warn-count=${warn_count}"
} >> "${GITHUB_OUTPUT}"

if [ "${deny_count}" -gt 0 ]; then
  echo "::error title=k8s-policy::${deny_count} policy violation(s)"
  exit 1
fi
if [ "${FAIL_ON_WARN}" = "true" ] && [ "${warn_count}" -gt 0 ]; then
  echo "::error title=k8s-policy::${warn_count} policy warning(s) with fail-on-warn enabled"
  exit 1
fi
echo "k8s-policy: no violations"
