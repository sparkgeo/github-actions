#!/usr/bin/env bash
# End-to-end check for the registry-config composite (issue #231), run by the
# ci.yml registry-config job on a GitHub-hosted runner (needs docker and sudo).
#
#   e2e.sh setup    start Verdaccio (npm) and devpi (PyPI) on localhost, with
#                   no upstream, publish one fixture package to each, write a
#                   package-lock.json whose URLs point at registry.npmjs.org,
#                   then blackhole registry.npmjs.org, pypi.org and
#                   files.pythonhosted.org in /etc/hosts
#   e2e.sh install  (after the composite ran) npm ci and pip install the
#                   fixtures; any request that bypasses the proxy fails
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/registry-e2e"
NPM_REG="http://localhost:4873/"
PKG=sparkgeo-registry-fixture
# verdaccio/verdaccio:6.10.4
VERDACCIO_IMAGE="verdaccio/verdaccio@sha256:43c4067288b050422265407ea2fe747e511fcd0c407a85ec90ab9a326d9400cd"
fail() { echo "FAIL: $*" >&2; exit 1; }

wait_for() {  # <url>
  for _ in $(seq 60); do curl -fsS -o /dev/null "$1" && return 0; sleep 1; done
  fail "$1 did not come up"
}

setup() {
  mkdir -p "${WORK}"

  echo "== Verdaccio"
  docker run -d --name verdaccio -p 4873:4873 \
    -v "${HERE}/fixtures/verdaccio.yaml:/verdaccio/conf/config.yaml:ro" "${VERDACCIO_IMAGE}" > /dev/null
  wait_for "${NPM_REG}-/ping"
  token="$(curl -fsS -X PUT -H 'content-type: application/json' \
    -d '{"name":"ci","password":"ci-fixture-only"}' "${NPM_REG}-/user/org.couchdb.user:ci" | jq -r .token)"
  mkdir -p "${WORK}/npm-pkg" "${WORK}/npm-app"
  printf '{"name":"%s","version":"1.0.0","main":"index.js","license":"MIT"}\n' "${PKG}" > "${WORK}/npm-pkg/package.json"
  echo 'module.exports = "served by the proxy";' > "${WORK}/npm-pkg/index.js"
  printf '//localhost:4873/:_authToken=%s\n' "${token}" > "${WORK}/publish.npmrc"
  (cd "${WORK}/npm-pkg" && npm publish --registry "${NPM_REG}" --userconfig "${WORK}/publish.npmrc")

  # A lockfile as a developer would commit it: resolved on registry.npmjs.org.
  printf '{"name":"app","version":"0.0.0","private":true,"dependencies":{"%s":"1.0.0"}}\n' "${PKG}" > "${WORK}/npm-app/package.json"
  (cd "${WORK}/npm-app" && npm install --package-lock-only --registry "${NPM_REG}" --userconfig /dev/null)
  sed -i 's#http://localhost:4873/#https://registry.npmjs.org/#' "${WORK}/npm-app/package-lock.json"
  grep -q '"resolved": "https://registry.npmjs.org/' "${WORK}/npm-app/package-lock.json" || fail "lockfile not rewritten"

  echo "== devpi"
  python3 -m venv "${WORK}/devpi"
  "${WORK}/devpi/bin/pip" install --quiet --require-hashes -r "${HERE}/requirements-devpi.txt"
  "${WORK}/devpi/bin/devpi-init" --serverdir "${WORK}/devpi-data" > /dev/null
  nohup "${WORK}/devpi/bin/devpi-server" --serverdir "${WORK}/devpi-data" --host 127.0.0.1 --port 3141 \
    > "${WORK}/devpi-server.out" 2>&1 &
  wait_for "http://localhost:3141/+api"
  dp() { "${WORK}/devpi/bin/devpi" --clientdir "${WORK}/devpi-client" "$@"; }
  dp use http://localhost:3141 > /dev/null
  dp login root --password '' > /dev/null
  dp index -c dev bases= volatile=True > /dev/null   # no root/pypi base: no upstream
  dp use root/dev > /dev/null
  python3 -I - "${WORK}/dist" <<'PY'
import base64, hashlib, os, sys, zipfile
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
name, ver = "sparkgeo_registry_fixture", "1.0.0"
di = f"{name}-{ver}.dist-info"
files = {
    f"{name}/__init__.py": 'SOURCE = "served by the proxy"\n',
    f"{di}/METADATA": f"Metadata-Version: 2.1\nName: sparkgeo-registry-fixture\nVersion: {ver}\n",
    f"{di}/WHEEL": "Wheel-Version: 1.0\nGenerator: e2e.sh\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
}
record = []
for p, c in files.items():
    d = base64.urlsafe_b64encode(hashlib.sha256(c.encode()).digest()).rstrip(b"=").decode()
    record.append(f"{p},sha256={d},{len(c.encode())}")
record.append(f"{di}/RECORD,,")
files[f"{di}/RECORD"] = "\n".join(record) + "\n"
with zipfile.ZipFile(f"{out}/{name}-{ver}-py3-none-any.whl", "w") as z:
    for p, c in files.items():
        z.writestr(p, c)
PY
  dp upload --from-dir "${WORK}/dist" > /dev/null

  echo "== blackhole the public registries"
  echo "0.0.0.0 registry.npmjs.org pypi.org files.pythonhosted.org" | sudo tee -a /etc/hosts > /dev/null
  if curl -fsS --max-time 10 -o /dev/null https://registry.npmjs.org/ 2>/dev/null; then fail "registry.npmjs.org still reachable"; fi
  if curl -fsS --max-time 10 -o /dev/null https://pypi.org/simple/ 2>/dev/null; then fail "pypi.org still reachable"; fi
  echo "setup done"
}

install() {
  echo "== npm ci through the proxy (lockfile says registry.npmjs.org)"
  # Empty cache: the tarball must come over the wire, not from the publish step.
  (cd "${WORK}/npm-app" && npm ci --no-audit --no-fund --cache "${WORK}/npm-ci-cache")
  [ "$(cd "${WORK}/npm-app" && node -p "require('${PKG}')")" = "served by the proxy" ] || fail "npm fixture not installed"
  served="$(docker logs verdaccio 2>&1)"  # not piped into grep -q: pipefail + SIGPIPE
  grep -q "GET /${PKG}/-/${PKG}-1.0.0.tgz" <<< "${served}" || fail "Verdaccio did not serve the tarball"

  echo "== pip install through the proxy"
  python3 -m venv "${WORK}/app-venv"
  "${WORK}/app-venv/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir "${PKG}==1.0.0"
  [ "$("${WORK}/app-venv/bin/python" -c 'import sparkgeo_registry_fixture as m; print(m.SOURCE)')" = "served by the proxy" ] \
    || fail "pip fixture not installed"

  echo "all registry-config e2e checks passed"
}

case "${1:-}" in
  setup) setup ;;
  install) install ;;
  *) echo "usage: e2e.sh setup|install" >&2; exit 2 ;;
esac
