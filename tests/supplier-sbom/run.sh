#!/usr/bin/env bash
# Supplier SBOM intake (issue #233): sbom.py (schema check, origin marking,
# unidentified components) and upload.sh against a stub Dependency-Track.
# Usage: tests/supplier-sbom/run.sh <venv bin dir with cyclonedx-python-lib[json-validation]>
set -euo pipefail
BIN="${1:?usage: run.sh <venv bin dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${HERE}/../../.github/actions/supplier-sbom"
WORK="$(mktemp -d)"
STUB_PID=""
trap '[ -z "${STUB_PID}" ] || kill "${STUB_PID}"; find "${WORK}" -delete' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected $3, got $2)"; fail=1; fi; }
sbompy() { "${BIN}/python" -I "${ACTION}/sbom.py" --output "${WORK}/out.json" --supplier acme-geo-sdk --version 4.2.0 "$@" 2> "${WORK}/stderr"; }

# A minimal valid CycloneDX 1.6 document with one identified and one unidentified component.
jq -n '{bomFormat: "CycloneDX", specVersion: "1.6", version: 1, components: [
  {type: "library", name: "zlib", version: "1.2.11", cpe: "cpe:2.3:a:zlib:zlib:1.2.11:*:*:*:*:*:*:*"},
  {type: "file", name: "vendor-blob"}]}' > "${WORK}/in.json"

status=0; sbompy --input "${WORK}/in.json" --origin generated-from-binary --tool cve-bin-tool > "${WORK}/counts" || status=$?
check "valid SBOM passes with counts" "$(tr '\n' ' ' < "${WORK}/counts")${status}" "component-count=2 unidentified-count=1 0"
check "unidentified component is warned about" "$(grep -c 'vendor-blob' "${WORK}/stderr")" "1"
check "generated SBOM is marked as ours" \
  "$(jq -r '[(.metadata.properties[] | select(.name == "sparkgeo:sbom-origin") | .value), .metadata.component.name, (.metadata.component.description | test("not an SBOM from the supplier"))] | join(" ")' "${WORK}/out.json")" \
  "generated-from-binary acme-geo-sdk true"

jq '.components[0] |= del(.type)' "${WORK}/in.json" > "${WORK}/bad.json"
status=0; sbompy --input "${WORK}/bad.json" --origin supplier-delivered > /dev/null || status=$?
check "schema violation is rejected" "$(grep -c "fails the CycloneDX 1.6 schema" "${WORK}/stderr")/${status}" "1/1"

"${BIN}/python" -I "${HERE}/stub_dtrack.py" "${WORK}" > "${WORK}/port" &
STUB_PID=$!
for _ in $(seq 50); do [ -s "${WORK}/port" ] && break; sleep 0.1; done
DTRACK_URL="http://127.0.0.1:$(cat "${WORK}/port")/" DTRACK_API_KEY=test-key SUPPLIER=acme-geo-sdk VERSION=4.2.0 PARENT=Suppliers \
  SBOM="${WORK}/in.json" VEX="${HERE}/fixtures/vendor.vex.cdx.json" bash "${ACTION}/upload.sh" > "${WORK}/upload.log"
check "BOM upload request" \
  "$(jq -r '"\(.api_key) \(.body.projectName) \(.body.projectVersion) \(.body.parentName) \(.body.autoCreate) \(.body.bom | @base64d | fromjson | .components | length)"' "${WORK}/bom.json")" \
  "test-key acme-geo-sdk 4.2.0 Suppliers true 2"
check "vendor VEX upload request" "$(jq -r '.body.vex | @base64d | fromjson | .vulnerabilities[0].id' "${WORK}/vex.json")" "CVE-2023-37920"
echo '{"@context": "https://openvex.dev/ns/v0.2.0", "statements": []}' > "${WORK}/openvex.json"
find "${WORK}" -name vex.json -delete
DTRACK_URL="http://127.0.0.1:$(cat "${WORK}/port")" DTRACK_API_KEY=test-key SUPPLIER=acme-geo-sdk VERSION=4.2.0 PARENT=Suppliers \
  SBOM="${WORK}/in.json" VEX="${WORK}/openvex.json" bash "${ACTION}/upload.sh" > "${WORK}/upload.log"
check "OpenVEX is kept, not uploaded" "$(grep -c 'not CycloneDX VEX' "${WORK}/upload.log")/$([ -f "${WORK}/vex.json" ] && echo sent || echo kept)" "1/kept"

exit "${fail}"
