#!/usr/bin/env bash
# Lint fixtures for sensor-rules-lint (issue #16). Needs docker (falco cases)
# and KUBECONFORM pointing at a kubeconform binary (tetragon cases).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
LINT="${ROOT}/.github/actions/sensor-rules-lint/lint.sh"
export SCHEMA_DIR="${ROOT}/policies/tetragon/schemas"
export FALCO_IMAGE="${FALCO_IMAGE:-falcosecurity/falco@sha256:788f1129c542171813083d4afc61b16730a47dde8c23d9c39370acef996349b6}"
export KUBECONFORM="${KUBECONFORM:?path to kubeconform}"
fails=0

# sensor | fixture dir | allow-enforcement | expected rc | text the log must contain
while IFS='|' read -r sensor dir allow want_rc want_text; do
  set +e
  out="$(SENSOR="${sensor}" RULES_DIR="${HERE}/fixtures/${dir}" ALLOW_ENFORCEMENT="${allow}" bash "${LINT}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" = "${want_rc}" ] && grep -qF -- "${want_text}" <<< "${out}"; then
    echo "ok   ${sensor} ${dir} allow=${allow} -> rc=${rc}"
  else
    echo "FAIL ${sensor} ${dir} allow=${allow} -> rc=${rc} (want ${want_rc}), missing '${want_text}':"
    tail -5 <<< "${out}"
    fails=$((fails + 1))
  fi
done <<'CASES'
falco|falco-good|false|0|demo-shell.yaml: Ok
falco|falco-bad|false|1|nosuchfield.x
falco|no-such-dir|false|0|nothing to validate
tetragon|tetragon-good|false|0|Valid: 1
tetragon|tetragon-enforce|false|1|enforcement action Sigkill is Advanced tier only
tetragon|tetragon-enforce|true|0|Valid: 1
tetragon|tetragon-invalid|false|1|kprobe
falco|tetragon-good|false|1|LOAD_ERR
bogus|falco-good|false|1|sensor must be falco or tetragon
CASES
echo "${fails} failure(s)"
exit "${fails}"
