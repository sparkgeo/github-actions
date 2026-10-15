#!/usr/bin/env bash
# Unit checks for registry-config/configure.sh in a throwaway HOME: no-op when
# empty, files written and read back by the real clients, existing settings
# kept, bad values rejected. The Docker step needs sudo and is covered by
# e2e.sh in CI. Needs bash, python3; npm, pip and go when present.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HERE}/../../.github/actions/registry-config/configure.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {  # <home> [VAR=value ...]; sets rc, output in <home>/out
  local home="$1"; shift
  mkdir -p "${home}"
  : > "${home}/out"
  set +e
  env -u XDG_CONFIG_HOME HOME="${home}" GITHUB_OUTPUT="${home}/out" NPM_URL= PYPI_URL= GO_URL= DOCKER_MIRROR= HF_URL= \
    "$@" bash "${CONF}" > "${home}/log" 2>&1
  rc=$?
  set -e
}

echo "== all empty: no-op"
run "${TMP}/empty"
[ "${rc}" -eq 0 ] || fail "rc ${rc}"
[ -z "$(find "${TMP}/empty" -mindepth 1 -not -name out -not -name log)" ] || fail "files written: $(find "${TMP}/empty" -mindepth 1)"
grep -qx 'configured=' "${TMP}/empty/out" || fail "configured should be empty"

echo "== npm, pypi, go, hf set; existing settings kept"
H="${TMP}/set"
mkdir -p "${H}/.config/pip"
printf 'registry=https://registry.npmjs.org/\nsave-exact=true\n' > "${H}/.npmrc"
printf '[global]\ntimeout = 30\n' > "${H}/.config/pip/pip.conf"
run "${H}" NPM_URL=http://localhost:4873/ PYPI_URL=http://localhost:8080/simple/ \
  GO_URL=https://athens.example/ HF_URL=https://hf.example/
[ "${rc}" -eq 0 ] || fail "rc ${rc}: $(cat "${H}/log")"
grep -qx 'configured=npm,pypi,go,huggingface' "${H}/out" || fail "configured: $(cat "${H}/out")"
grep -qx 'hf-endpoint=https://hf.example/' "${H}/out" || fail "hf-endpoint"
[ "$(grep -c '^registry=' "${H}/.npmrc")" = 1 ] || fail "npmrc registry not replaced"
grep -qx 'registry=http://localhost:4873/' "${H}/.npmrc" || fail "npmrc registry"
grep -qx 'save-exact=true' "${H}/.npmrc" || fail "npmrc lost other settings"
grep -q '^timeout = 30' "${H}/.config/pip/pip.conf" || fail "pip.conf lost timeout"
grep -q '^index-url = http://localhost:8080/simple/' "${H}/.config/pip/pip.conf" || fail "pip index-url"
grep -q '^url = "http://localhost:8080/simple/"' "${H}/.config/uv/uv.toml" || fail "uv index"
grep -qx 'GOPROXY=https://athens.example/' "${H}/.config/go/env" || fail "GOPROXY"
grep -qx 'GONOSUMDB=' "${H}/.config/go/env" || fail "GONOSUMDB"

echo "== the clients read it back"
if command -v npm > /dev/null; then
  [ "$(env -u XDG_CONFIG_HOME HOME="${H}" npm config get registry)" = "http://localhost:4873/" ] || fail "npm reads $(env -u XDG_CONFIG_HOME HOME="${H}" npm config get registry)"
fi
if python3 -m pip --version > /dev/null 2>&1; then
  env -u XDG_CONFIG_HOME HOME="${H}" python3 -m pip config list 2>/dev/null | grep -q "global.index-url='http://localhost:8080/simple/'" \
    || fail "pip reads: $(env -u XDG_CONFIG_HOME HOME="${H}" python3 -m pip config list 2>&1)"
fi
if command -v go > /dev/null; then
  [ "$(env -u GOPROXY -u XDG_CONFIG_HOME HOME="${H}" go env GOPROXY)" = "https://athens.example/" ] || fail "go reads $(env -u GOPROXY -u XDG_CONFIG_HOME HOME="${H}" go env GOPROXY)"
fi

echo "== second run replaces, does not duplicate"
run "${H}" NPM_URL=https://proxy.example/npm/ GO_URL=https://proxy.example/go/
[ "$(grep -c '^registry=' "${H}/.npmrc")" = 1 ] || fail "npmrc registry duplicated"
grep -qx 'registry=https://proxy.example/npm/' "${H}/.npmrc" || fail "npmrc rerun"
[ "$(grep -c '^GOPROXY=' "${H}/.config/go/env")" = 1 ] || fail "go env rerun"

echo "== bad values rejected"
for bad in 'ftp://x/' 'https://a.example/ registry=https://evil.example/' "$(printf 'https://a.example/\nregistry=https://evil.example/')"; do
  run "${TMP}/bad" NPM_URL="${bad}"
  [ "${rc}" -eq 1 ] || fail "accepted '${bad}'"
  [ ! -e "${TMP}/bad/.npmrc" ] || fail "wrote npmrc for '${bad}'"
done

echo "== plain http outside localhost warns"
run "${TMP}/http" PYPI_URL=http://proxy.internal/simple/
[ "${rc}" -eq 0 ] || fail "rc ${rc}"
grep -q '::warning' "${TMP}/http/log" || fail "no http warning"

echo "all registry-config checks passed"
