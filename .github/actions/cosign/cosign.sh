#!/usr/bin/env bash
# Sign or verify a container image with cosign (Sigstore keyless).
#
# Env: COSIGN (binary path), MODE (sign|verify), IMAGE (digest reference,
# registry/repo@sha256:...), IDENTITY_REGEXP and OIDC_ISSUER (verify only).
# Outputs: identity (the signer's certificate subject on a successful verify
# of a legacy-format signature; empty for bundle-format signatures and on
# failure. The identity regexp is enforced either way).
# Exit: 0 ok, 1 signing/verification failed, 2 bad input.
set -euo pipefail

: "${COSIGN:?}" "${MODE:?}" "${IMAGE:?}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

case "${MODE}" in
  sign|verify) ;;
  *) echo "::error title=cosign::mode must be sign or verify, got '${MODE}'"; exit 2 ;;
esac
case "${IMAGE}" in
  *@sha256:*) ;;
  *) echo "::error title=cosign::image must be a digest reference (registry/repo@sha256:...), got '${IMAGE}'"; exit 2 ;;
esac

if [ "${MODE}" = "sign" ]; then
  echo "Signing ${IMAGE}"
  if ! "${COSIGN}" sign --yes "${IMAGE}"; then
    echo "::error title=cosign::signing failed for ${IMAGE}"
    exit 1
  fi
  {
    echo "### Container sign (cosign)"
    echo
    echo "Signed \`${IMAGE}\` keylessly; the signature is stored next to the image in the registry."
  } >> "${GITHUB_STEP_SUMMARY}"
  echo "identity=" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if [ -z "${IDENTITY_REGEXP:-}" ]; then
  echo "::error title=cosign::certificate-identity-regexp is required for verify"
  exit 2
fi
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

echo "Verifying ${IMAGE} (identity ~ ${IDENTITY_REGEXP}, issuer ${OIDC_ISSUER})"
set +e
RESULT="$("${COSIGN}" verify \
  --certificate-identity-regexp "${IDENTITY_REGEXP}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  --output json "${IMAGE}" 2> >(sed 's/^/cosign: /' >&2))"
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "::error title=cosign::signature verification failed for ${IMAGE} (no signature from an identity matching ${IDENTITY_REGEXP} issued by ${OIDC_ISSUER})"
  echo "identity=" >> "${GITHUB_OUTPUT}"
  exit 1
fi

# cosign only includes the certificate subject in its output for legacy
# (pre-bundle) signatures; for the Sigstore bundle format cosign v3 signs
# with by default, the subject is absent, although the identity regexp was
# still enforced above. Report what we have.
IDENTITY="$(jq -r '.[0].optional.Subject // ""' <<< "${RESULT}")"
if [ -n "${IDENTITY}" ]; then
  SIGNER="${IDENTITY}"
  echo "Verified: signed by ${IDENTITY}"
else
  SIGNER="an identity matching ${IDENTITY_REGEXP} (subject not reported for bundle-format signatures)"
  echo "Verified: signed by ${SIGNER}"
fi
{
  echo "### Container verify (cosign)"
  echo
  echo "| Image | Signer | Issuer |"
  echo "|-------|--------|--------|"
  echo "| \`${IMAGE}\` | \`${SIGNER}\` | \`${OIDC_ISSUER}\` |"
} >> "${GITHUB_STEP_SUMMARY}"
echo "identity=${IDENTITY}" >> "${GITHUB_OUTPUT}"
