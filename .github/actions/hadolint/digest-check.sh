#!/usr/bin/env bash
# Every FROM in the given Dockerfiles must reference an image by digest
# (@sha256:...). Stage aliases (FROM build), scratch, and --platform flags are
# handled; FROM ${ARG} is resolved from the ARG default declared earlier in the
# same file and fails as unverifiable otherwise. Emits one ::error annotation
# per violation and writes unpinned-count to GITHUB_OUTPUT. Exit 1 on any
# violation. Rationale: SecOps plan Step 24; hadolint DL3006/DL3007 accept a
# digest-less tag, so this check is separate.
set -euo pipefail

total=0
for file in "$@"; do
  [ -f "${file}" ] || { echo "::error title=digest-pin::${file}: not found"; total=$((total+1)); continue; }
  declare -A args=() stages=()
  lineno=0
  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno+1))
    # Strip comments and surrounding whitespace; join nothing (one line at a time is enough for FROM/ARG).
    stripped="${line%%#*}"
    stripped="$(printf '%s' "${stripped}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "${stripped}" ] || continue
    keyword="$(printf '%s' "${stripped}" | awk '{print toupper($1)}')"
    case "${keyword}" in
      ARG)
        # ARG NAME=default  (quotes optional)
        rest="${stripped#* }"
        name="${rest%%=*}"
        if [ "${rest}" != "${name}" ]; then
          val="${rest#*=}"; val="${val%\"}"; val="${val#\"}"
          args["${name}"]="${val}"
        fi
        ;;
      FROM)
        rest="${stripped#* }"
        # Drop --platform=... and other flags. Word splitting is the point here.
        # shellcheck disable=SC2086
        set -- ${rest}
        while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done
        image="${1:-}"
        alias=""
        if [ $# -ge 3 ] && [ "$(printf '%s' "$2" | awk '{print toupper($0)}')" = "AS" ]; then alias="$3"; fi
        # Resolve ${VAR} / $VAR from in-file ARG defaults.
        resolved="${image}"
        if [[ "${resolved}" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; then
          var="${BASH_REMATCH[1]}"
          if [ -n "${args[${var}]+x}" ]; then
            resolved="${resolved//\$\{${var}\}/${args[${var}]}}"
            resolved="${resolved//\$${var}/${args[${var}]}}"
          else
            echo "::error file=${file},line=${lineno},title=digest-pin::FROM ${image}: cannot verify a digest; ARG ${var} has no in-file default"
            total=$((total+1)); [ -n "${alias}" ] && stages["${alias}"]=1; continue
          fi
        fi
        if [ "${resolved}" = "scratch" ] || [ -n "${stages[${resolved}]+x}" ]; then
          [ -n "${alias}" ] && stages["${alias}"]=1; continue
        fi
        if [[ "${resolved}" != *@sha256:* ]]; then
          echo "::error file=${file},line=${lineno},title=digest-pin::FROM ${image}: base image must be pinned by digest (image:tag@sha256:...)"
          total=$((total+1))
        fi
        [ -n "${alias}" ] && stages["${alias}"]=1
        ;;
    esac
  done < "${file}"
  unset args stages
done

echo "unpinned-count=${total}" >> "${GITHUB_OUTPUT:-/dev/null}"
if [ "${total}" -gt 0 ]; then
  echo "digest-pin: ${total} FROM line(s) without a digest"
  exit 1
fi
echo "digest-pin: all FROM lines pinned by digest"
