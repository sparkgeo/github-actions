#!/usr/bin/env bash
# Synthesise a CDK app and lay its templates out for Infracost (issue #90).
# Usage: synth.sh <checkout> <working-dir> <node|python> <cdk-version> <synth-args> <plans-dir> <stacks-file>
# Installs the app's dependencies in <checkout>/<working-dir>, runs
# `cdk synth <synth-args> --quiet` into a private output directory, copies
# every *.template.json (stages' nested assemblies included) to
# <plans-dir>/<stack>/plan.json, the layout mkconfig.sh reads, and appends
# each stack name to <stacks-file>. Infracost detects a CloudFormation
# template by its content, so the file name does not matter.
set -euo pipefail
CHECKOUT="$1"; WORKDIR="$2"; RUNTIME="$3"; CDK_VERSION="$4"; SYNTH_ARGS="$5"; PLANS="$6"; STACKS="$7"

APP="${CHECKOUT}/${WORKDIR}"
[ -f "${APP}/cdk.json" ] || { echo "::error title=infracost::no cdk.json in ${APP}"; exit 1; }
OUT="$(mktemp -d)"
cd "${APP}"
case "${RUNTIME}" in
  node) if [ -f package-lock.json ]; then npm ci --no-audit --no-fund > /dev/null; else npm install --no-audit --no-fund > /dev/null; fi ;;
  python)
    python3 -m venv "${OUT}.venv"
    "${OUT}.venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
    PATH="${OUT}.venv/bin:${PATH}" ;;
  *) echo "::error title=infracost::runtime must be node or python"; exit 1 ;;
esac
# Word splitting of SYNTH_ARGS is intended: it carries CLI flags such as "--all".
# shellcheck disable=SC2086
npx --yes "aws-cdk@${CDK_VERSION}" synth ${SYNTH_ARGS} --quiet -o "${OUT}" > "${OUT}.log" 2>&1 \
  || { cat "${OUT}.log"; echo "::error title=infracost::cdk synth failed in ${APP}"; exit 1; }

mkdir -p "${PLANS}"
count=0
while IFS= read -r template; do
  rel="${template#"${OUT}"/}"
  # A stage's stacks live in assembly-<Stage>/; keep the stage in the name.
  name="$(dirname "${rel}" | sed 's#^\.$##; s#^assembly-##; s#/assembly-#-#g; s#/#-#g')"
  stack="$(basename "${template}" .template.json)"
  stack="${name:+${name}-}${stack}"
  mkdir -p "${PLANS}/${stack}"
  cp "${template}" "${PLANS}/${stack}/plan.json"
  echo "${stack}" >> "${STACKS}"
  count=$((count + 1))
done < <(find "${OUT}" -name '*.template.json' | sort)
find "${OUT}" -type f -delete
echo "synthesised ${count} stack template(s) from ${APP}"
