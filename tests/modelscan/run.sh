#!/usr/bin/env bash
# Checks the modelscan composite's report.py against the fixture repository:
# a live modelscan of a malicious and a safe pickle, the fail-on-severity
# gate, a SavedModel directory without the tensorflow extra, key-mode
# signature verification (a signed model, a tampered copy, require-signature),
# the runtime-model manifest pin, and the ML-BOM contents (models, MCP
# server, skill, agent row). Needs python3, jq and the scanners (MODELSCAN,
# MODEL_SIGNING; default pipx run).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
REPORT="${ROOT}/.github/actions/modelscan/report.py"
FIX="${HERE}/fixtures/repo"
MODELSCAN_VERSION="${MODELSCAN_VERSION:-0.8.8}"
MODELSCAN="${MODELSCAN:-pipx run --spec modelscan[h5py]==${MODELSCAN_VERSION} modelscan}"
MODEL_SIGNING="${MODEL_SIGNING:-pipx run --spec model-signing==1.1.1 model_signing}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
scan() {  # <name> <root> <path>; modelscan exit codes 0/1/2 all leave a report
  set +e
  (cd "$2" && ${MODELSCAN} -p "$3" -r json -o "${TMP}/$1.scan.json" --show-skipped > "${TMP}/$1.scan.txt" 2>&1)
  scan_rc=$?
  set -e
  [ -f "${TMP}/$1.scan.json" ] || fail "modelscan $1 rc ${scan_rc}: $(tail -3 "${TMP}/$1.scan.txt")"
}
run() {  # <name> <root> <scan json> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${REPORT}" --root "$2" --scan "$3" --output "${TMP}/$1.json" --mlbom "${TMP}/$1.mlbom.json" \
    --model-signing-cmd "${MODEL_SIGNING}" "${@:4}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
errors() { jq -r '.errors | length' "${TMP}/$1.json"; }
copy() { rm -rf "${TMP:?}/$1"; cp -r "${FIX}" "${TMP}/$1"; }

echo "== models/: the malicious pickle is CRITICAL, key verification passes, manifest pins hold"
scan models "${FIX}" models
[ "${scan_rc}" -eq 1 ] || fail "modelscan should exit 1 on issues, got ${scan_rc}"
run models "${FIX}" "${TMP}/models.scan.json" --verify key --public-key keys/model-signing.pub
[ "${rc}" -eq 1 ] || fail "models rc ${rc}: $(cat "${TMP}/models.log")"
grep -q "^::error title=model-scan::models/evil.pkl: CRITICAL: Use of unsafe operator 'system' from module 'posix' (PickleUnsafeOpScan)" "${TMP}/models.log" || fail "critical issue: $(grep evil "${TMP}/models.log")"
[ "$(errors models)" = "1" ] || fail "only the pickle should fail: $(jq -c .errors "${TMP}/models.json")"
[ "$(jq -r '.models["models/signed.pkl"].verified' "${TMP}/models.json")" = "true" ] || fail "signed model verified"
grep -q '^::warning title=model-scan::models/safe.pkl: unsigned (no models/safe.pkl.sig)' "${TMP}/models.log" || fail "unsigned warning"
grep -q '^## Model scan: 5 model(s), 2 manifest entries, 10 ML-BOM component(s), 1 error(s), 4 warning(s)' "${TMP}/models.summary" || fail "summary: $(head -1 "${TMP}/models.summary")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| `models/signed.pkl` | `[0-9a-f]*` | CLEAN | verified |' "${TMP}/models.summary" || fail "summary row"
[ "$(grep '^model-count=' "${TMP}/models.out" | cut -d= -f2)" = "5" ] || fail "model-count output"
[ "$(jq -r '.notices | length' "${TMP}/models.json")" = "3" ] || fail "one safetensors notice per pickle: $(jq -c .notices "${TMP}/models.json")"
grep -q '^::notice title=model-scan::models/safe.pkl: pickle format runs code on load; prefer a safetensors export' "${TMP}/models.log" || fail "safetensors notice"
grep -q 'weights.safetensors: pickle' "${TMP}/models.log" && fail "no notice for safetensors"
[ "$(jq -r '.models["models/weights.safetensors"].format + " " + .models["models/safe.pkl"].format' "${TMP}/models.json")" = "safetensors pickle" ] || fail "formats"

echo "== ML-BOM: models with hashes, runtime model, MCP server, skill, active agent row (retired row excluded)"
B="${TMP}/models.mlbom.json"
[ "$(jq -r '.bomFormat + " " + .specVersion' "${B}")" = "CycloneDX 1.6" ] || fail "bom header"
[ "$(jq -r '[.components[] | select(.type == "machine-learning-model")] | length' "${B}")" = "6" ] || fail "model components: $(jq -c '[.components[].name]' "${B}")"
[ "$(jq -r '.components[] | select(.name == "signed-demo") | .hashes[0].content' "${B}")" = "$(sha256sum "${FIX}/models/signed.pkl" | cut -d' ' -f1)" ] || fail "manifest model hash"
[ "$(jq -r '.components[] | select(.name == "signed-demo") | .licenses[0].license.id + " " + .externalReferences[0].url' "${B}")" = "Apache-2.0 https://example.com/models/signed-demo" ] || fail "manifest licence and source"
[ "$(jq -r '.components[] | select(.name == "runtime-embedder") | .properties[0].value + " " + .hashes[0].content[0:8]' "${B}")" = "true 53aa5117" ] || fail "runtime model"
[ "$(jq -r '.components[] | select(.name == "runtime-embedder") | .licenses[0].license.id + " " + .modelCard.modelParameters.datasets[0].ref' "${B}")" = "Apache-2.0 data:s2orc" ] || fail "runtime licence and dataset ref"
[ "$(jq -r '.components[] | select(.["bom-ref"] == "data:s2orc") | .type + " " + .licenses[0].license.id + " " + .externalReferences[0].url' "${B}")" = "data ODC-By-1.0 https://github.com/allenai/s2orc" ] || fail "dataset component"
[ "$(jq -r '.components[] | select(.name == "signed-demo") | .properties[] | select(.name == "sparkgeo:format") | .value' "${B}")" = "pickle" ] || fail "format property"
[ "$(jq -r '.components[] | select(.name == "fixture-stdio") | .type + " " + .hashes[0].content[0:12]' "${B}")" = "application 35c62fd256db" ] || fail "mcp server component"
[ "$(jq -r '.components[] | select(.name == ".claude/skills/deploy/SKILL.md") | .type' "${B}")" = "file" ] || fail "skill component"
[ "$(jq -r '[.components[] | select(.["bom-ref"] | startswith("agent:"))] | map(.name) | join(",")' "${B}")" = "Claude Code (developer)" ] || fail "agent rows: $(jq -c '[.components[]["bom-ref"]]' "${B}")"
[ "$(jq -r '.components[] | select(.name == "Claude Code (developer)") | .properties[] | select(.name == "sparkgeo:owner") | .value' "${B}")" = "team-x" ] || fail "agent owner property"

echo "== fail-on-severity critical still fails CRITICAL; a MEDIUM-only report passes at high"
run crit "${FIX}" "${TMP}/models.scan.json" --fail-on-severity critical
[ "$(errors crit)" = "1" ] || fail "critical threshold"
jq '.issues[0].severity = "MEDIUM"' "${TMP}/models.scan.json" > "${TMP}/medium.scan.json"
run medium "${FIX}" "${TMP}/medium.scan.json"
[ "${rc}" -eq 0 ] || fail "medium below high must pass: $(jq -c .errors "${TMP}/medium.json")"
[ "$(jq -r '.models["models/evil.pkl"].severity' "${TMP}/medium.json")" = "medium" ] || fail "severity recorded"
run low "${FIX}" "${TMP}/medium.scan.json" --fail-on-severity low
[ "$(errors low)" = "1" ] || fail "low threshold"

echo "== SavedModel directory without the tensorflow extra is a modelscan error, hashed as one model"
scan tf "${FIX}" tf
run tf "${FIX}" "${TMP}/tf.scan.json"
grep -q "^::error title=model-scan::tf/savedmodel/saved_model.pb: modelscan dependency: To use modelscan.scanners.SavedModelLambdaDetectScan, please install modelscan with tensorflow extras" "${TMP}/tf.log" || fail "dependency error: $(grep saved_model "${TMP}/tf.log")"
[ "$(jq -r '.models["tf/savedmodel"].sha256 | length' "${TMP}/tf.json")" = "64" ] || fail "savedmodel dir hashed"

echo "== tampered signed model fails verification; require-signature fails the unsigned ones"
copy tamper
echo tampered >> "${TMP}/tamper/models/signed.pkl"
run tamper "${TMP}/tamper" "${TMP}/models.scan.json" --verify key --public-key keys/model-signing.pub --fail-on-severity critical
grep -q '^::error title=model-scan::models/signed.pkl: signature models/signed.pkl.sig did not verify: Verification failed with error: Signature mismatch' "${TMP}/tamper.log" || fail "tamper error: $(grep signed "${TMP}/tamper.log")"
grep -q '^::error title=model-scan::models.json: signed-demo: sha256 [0-9a-f]* does not match the file' "${TMP}/tamper.log" || fail "manifest pin error"
run require "${FIX}" "${TMP}/models.scan.json" --verify key --public-key keys/model-signing.pub --require-signature --fail-on-severity critical
[ "$(errors require)" = "5" ] || fail "require-signature: 1 pickle + 4 unsigned: $(jq -c .errors "${TMP}/require.json")"
grep -q '^::error title=model-scan::models/safe.pkl: unsigned (no models/safe.pkl.sig); require-signature is on' "${TMP}/require.log" || fail "unsigned error"

echo "== manifest entry without sha256 or with a missing path is an error"
copy manifest
jq '.models[1].sha256 = "" | .models += [{"name": "ghost", "path": "models/ghost.pt", "source": "x", "sha256": "00"}]' "${FIX}/models.json" > "${TMP}/manifest/models.json"
run manifest "${TMP}/manifest" "${TMP}/models.scan.json" --fail-on-severity critical
grep -q '^::error title=model-scan::models.json: runtime-embedder: no sha256; a model loaded at runtime is pinned by hash' "${TMP}/manifest.log" || fail "unpinned runtime model"
grep -q '^::error title=model-scan::models.json: ghost: path models/ghost.pt is not in the repository' "${TMP}/manifest.log" || fail "ghost path"

echo "== discovery limited to --paths: the tf/ fixture only"
run paths "${FIX}" "" --paths tf --fail-on-severity critical
[ "$(jq -r '.models | keys | join(",")' "${TMP}/paths.json")" = "tf/savedmodel" ] || fail "paths discovery: $(jq -c '.models | keys' "${TMP}/paths.json")"

echo "== repository without models, manifest, lock or inventory passes with an empty ML-BOM"
mkdir -p "${TMP}/empty"
run empty "${TMP}/empty" ""
[ "${rc}" -eq 0 ] || fail "empty rc ${rc}: $(cat "${TMP}/empty.log")"
[ "$(jq -r '.components | length' "${TMP}/empty.mlbom.json")" = "0" ] || fail "empty bom"

echo "all modelscan checks passed"
