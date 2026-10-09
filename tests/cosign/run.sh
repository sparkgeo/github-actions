#!/usr/bin/env bash
# Checks cosign.sh (the script behind .github/actions/cosign) in verify mode
# against a public image that Chainguard signs keylessly from GitHub Actions.
# Needs cosign on PATH or in $COSIGN, docker buildx, jq, and network access
# to cgr.dev and Sigstore (rekor, tuf-repo-cdn).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../../.github/actions/cosign/cosign.sh"
COSIGN="${COSIGN:-cosign}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

IMAGE_TAG="cgr.dev/chainguard/static:latest"
IDENTITY='^https://github\.com/chainguard-images/images/\.github/workflows/release\.yaml@refs/heads/main$'

run() {  # <mode> <image> <identity-regexp>
  rm -f "${TMP}/out" "${TMP}/summary"
  touch "${TMP}/out" "${TMP}/summary"
  set +e
  COSIGN="${COSIGN}" MODE="$1" IMAGE="$2" IDENTITY_REGEXP="$3" \
    OIDC_ISSUER="https://token.actions.githubusercontent.com" \
    GITHUB_OUTPUT="${TMP}/out" GITHUB_STEP_SUMMARY="${TMP}/summary" \
    bash "${SCRIPT}" > "${TMP}/log" 2>&1
  rc=$?
  set -e
}

# Resolve the tag to a digest reference once; the script only accepts digests.
DIGEST="$(docker buildx imagetools inspect "${IMAGE_TAG}" --format '{{json .Manifest}}' | jq -r .digest)"
IMAGE="cgr.dev/chainguard/static@${DIGEST}"
case "${IMAGE}" in
  cgr.dev/chainguard/static@sha256:*) ;;
  *) fail "could not resolve ${IMAGE_TAG} to a digest (got '${IMAGE}')" ;;
esac

echo "== verify: matching identity passes"
run verify "${IMAGE}" "${IDENTITY}"
[ "${rc}" -eq 0 ] || { cat "${TMP}/log"; fail "verify: expected rc 0, got ${rc}"; }
grep -q '^identity=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main$' "${TMP}/out" || fail "verify: identity output"
grep -q 'chainguard-images/images' "${TMP}/summary" || fail "verify: summary names the signer"

echo "== verify: wrong identity fails"
run verify "${IMAGE}" '^https://github\.com/nobody/'
[ "${rc}" -eq 1 ] || fail "wrong identity: expected rc 1, got ${rc}"
grep -q "^::error title=cosign::signature verification failed for ${IMAGE}" "${TMP}/log" || fail "wrong identity: error annotation"
grep -q '^identity=$' "${TMP}/out" || fail "wrong identity: identity output should be empty"

echo "== tag reference rejected"
run verify "${IMAGE_TAG}" "${IDENTITY}"
[ "${rc}" -eq 2 ] || fail "tag ref: expected rc 2, got ${rc}"
grep -q '::error title=cosign::image must be a digest reference' "${TMP}/log" || fail "tag ref: error annotation"

echo "== verify without identity rejected"
run verify "${IMAGE}" ""
[ "${rc}" -eq 2 ] || fail "no identity: expected rc 2, got ${rc}"

echo "== unknown mode rejected"
run attest "${IMAGE}" "${IDENTITY}"
[ "${rc}" -eq 2 ] || fail "unknown mode: expected rc 2, got ${rc}"
grep -q "::error title=cosign::mode must be sign or verify" "${TMP}/log" || fail "unknown mode: error annotation"

echo "PASS"
