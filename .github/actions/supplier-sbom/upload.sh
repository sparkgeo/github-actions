#!/usr/bin/env bash
# Upload a supplier SBOM, and the vendor's VEX when delivered, to
# Dependency-Track as project <supplier> <version> under the parent project
# "Suppliers" (issue #233). Uses PUT /api/v1/bom and PUT /api/v1/vex, which
# both Dependency-Track v4 and v5 serve.
# Env: DTRACK_URL, DTRACK_API_KEY, SUPPLIER, VERSION, PARENT, SBOM, VEX (optional).
set -euo pipefail
: "${DTRACK_URL:?}" "${DTRACK_API_KEY:?}" "${SUPPLIER:?}" "${VERSION:?}" "${PARENT:?}" "${SBOM:?}"

WORK="$(mktemp -d)"
# The key goes in a header file so it never appears in the process list.
printf 'X-Api-Key: %s\nContent-Type: application/json\n' "${DTRACK_API_KEY}" > "${WORK}/headers"
put() {  # <endpoint> <json body file>
  curl -sS --fail-with-body -X PUT "${DTRACK_URL%/}/api/v1/$1" -H @"${WORK}/headers" --data @"$2"
}

base64 -w0 "${SBOM}" > "${WORK}/sbom.b64"
jq -n --arg n "${SUPPLIER}" --arg v "${VERSION}" --arg p "${PARENT}" --rawfile b "${WORK}/sbom.b64" \
  '{projectName: $n, projectVersion: $v, autoCreate: true, parentName: $p, bom: $b}' > "${WORK}/bom.json"
token="$(put bom "${WORK}/bom.json" | jq -r '.token // empty')"
echo "::notice title=supplier-sbom::uploaded ${SUPPLIER} ${VERSION} to Dependency-Track (processing token ${token:-none})"

if [ -n "${VEX:-}" ]; then
  if [ "$(jq -r '.bomFormat // empty' "${VEX}")" != "CycloneDX" ]; then
    # Dependency-Track ingests CycloneDX VEX only; an OpenVEX file stays an artefact.
    echo "::warning title=supplier-sbom::${VEX} is not CycloneDX VEX; kept as an artefact, not uploaded"
  else
    base64 -w0 "${VEX}" > "${WORK}/vex.b64"
    jq -n --arg n "${SUPPLIER}" --arg v "${VERSION}" --rawfile b "${WORK}/vex.b64" \
      '{projectName: $n, projectVersion: $v, vex: $b}' > "${WORK}/vex.json"
    put vex "${WORK}/vex.json" > /dev/null
    echo "::notice title=supplier-sbom::uploaded the vendor VEX for ${SUPPLIER} ${VERSION}"
  fi
fi
