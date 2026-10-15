#!/usr/bin/env bash
# Points package clients at the org proxy registry (issue #231). Inputs via
# env: NPM_URL, PYPI_URL, GO_URL, DOCKER_MIRROR, HF_URL; each empty = leave
# that client alone. Writes user-level config files rather than GITHUB_ENV, so
# every later step and tool (pre-commit hook envs, npm ci, go build) reads
# them. Writes `configured` and `hf-endpoint` to GITHUB_OUTPUT.
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}"
configured=()

check_url() {  # <name> <value>: one http(s) URL, no whitespace (values land in config files)
  if [[ ! "$2" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "::error title=registry-config::$1 must be a single http(s) URL, got '$2'"
    exit 1
  fi
  if [[ "$2" == http://* && ! "$2" =~ ^http://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
    echo "::warning title=registry-config::$1 uses plain http outside localhost; packages travel unencrypted"
  fi
}

set_line() {  # <file> <key> <line>: replace any existing "<key>=" line
  mkdir -p "$(dirname "$1")"
  touch "$1"
  sed -i "/^$2=/d" "$1"
  echo "$3" >> "$1"
}

if [ -n "${NPM_URL:-}" ]; then
  check_url npm-url "${NPM_URL}"
  # npm's default replace-registry-host=npmjs rewrites registry.npmjs.org
  # URLs in package-lock.json to this registry, so `npm ci` follows it too.
  set_line "${HOME}/.npmrc" registry "registry=${NPM_URL}"
  configured+=(npm)
fi

if [ -n "${PYPI_URL:-}" ]; then
  check_url pypi-url "${PYPI_URL}"
  mkdir -p "${CONFIG}/pip" "${CONFIG}/uv"
  python3 -I - "${CONFIG}/pip/pip.conf" "${PYPI_URL}" <<'PY'
import configparser, sys
c = configparser.ConfigParser()
c.read(sys.argv[1])
c.setdefault("global", {})
c["global"]["index-url"] = sys.argv[2]
with open(sys.argv[1], "w") as f:
    c.write(f)
PY
  if [ -s "${CONFIG}/uv/uv.toml" ]; then
    echo "::warning title=registry-config::${CONFIG}/uv/uv.toml exists; not changed (set the index there)"
  else
    printf '[[index]]\nurl = "%s"\ndefault = true\n' "${PYPI_URL}" > "${CONFIG}/uv/uv.toml"
  fi
  configured+=(pypi)
fi

if [ -n "${GO_URL:-}" ]; then
  check_url go-url "${GO_URL}"
  # No ",direct" fallback: a module the proxy lacks fails instead of going
  # around it. GOSUMDB stays on; go fetches it through the proxy's /sumdb/.
  set_line "${CONFIG}/go/env" GOPROXY "GOPROXY=${GO_URL}"
  set_line "${CONFIG}/go/env" GONOSUMDB "GONOSUMDB="
  configured+=(go)
fi

if [ -n "${DOCKER_MIRROR:-}" ]; then
  check_url docker-mirror "${DOCKER_MIRROR}"
  # Docker Hub pulls only; images named with another registry are not mirrored.
  daemon=/etc/docker/daemon.json
  current="$(sudo cat "${daemon}" 2>/dev/null || echo '{}')"
  jq --arg m "${DOCKER_MIRROR}" '."registry-mirrors" = ([$m] + ((."registry-mirrors" // []) - [$m]))' <<< "${current}" \
    | sudo tee "${daemon}" > /dev/null
  sudo systemctl restart docker
  configured+=(docker)
fi

if [ -n "${HF_URL:-}" ]; then
  check_url hf-url "${HF_URL}"
  configured+=(huggingface)
fi

list="$(IFS=,; echo "${configured[*]}")"
{
  echo "configured=${list}"
  echo "hf-endpoint=${HF_URL:-}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
if [ -z "${list}" ]; then
  echo "registry-config: no proxy variables set; clients use their public registries"
else
  echo "registry-config: proxy configured for ${list}"
fi
