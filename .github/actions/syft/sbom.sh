#!/usr/bin/env bash
# Generate SBOMs with syft. One syft invocation writes every requested format.
#
# Env: SYFT (binary path), TARGET (directory or image reference), FORMATS
# (comma-separated: cyclonedx-json, spdx-json), OUTPUT_DIR.
# Outputs: sbom-dir, files (comma-separated file names inside sbom-dir).
set -euo pipefail

: "${SYFT:?}" "${TARGET:?}" "${FORMATS:?}" "${OUTPUT_DIR:?}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

ARGS=()
FILES=()
IFS=',' read -ra WANTED <<< "${FORMATS}"
for fmt in "${WANTED[@]}"; do
  fmt="${fmt// /}"
  case "${fmt}" in
    cyclonedx-json) file="sbom.cyclonedx.json" ;;
    spdx-json)      file="sbom.spdx.json" ;;
    *) echo "::error title=syft::unsupported format '${fmt}' (use cyclonedx-json, spdx-json)"; exit 1 ;;
  esac
  ARGS+=(-o "${fmt}=${OUTPUT_DIR}/${file}")
  FILES+=("${file}")
done

mkdir -p "${OUTPUT_DIR}"
echo "Generating SBOM for ${TARGET} (${FORMATS})"
"${SYFT}" scan "${TARGET}" --quiet "${ARGS[@]}"

{
  echo "### SBOM (syft)"
  echo
  echo "Target: \`${TARGET}\`"
  echo
  echo "| File | Packages |"
  echo "|------|----------|"
  for file in "${FILES[@]}"; do
    case "${file}" in
      # Count packages only: syft also lists the scanned files/root as entries.
      sbom.cyclonedx.json) n="$(jq '[.components[] | select(.type != "file")] | length' "${OUTPUT_DIR}/${file}")" ;;
      sbom.spdx.json)      n="$(jq '[.packages[] | select(.SPDXID | startswith("SPDXRef-Package-"))] | length' "${OUTPUT_DIR}/${file}")" ;;
    esac
    echo "| ${file} | ${n} |"
  done
} >> "${GITHUB_STEP_SUMMARY}"

{
  echo "sbom-dir=${OUTPUT_DIR}"
  echo "files=$(IFS=','; echo "${FILES[*]}")"
} >> "${GITHUB_OUTPUT}"
