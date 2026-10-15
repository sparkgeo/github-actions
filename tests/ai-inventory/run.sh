#!/usr/bin/env bash
# Checks check.py against a fixture repository: covered files, a file with no
# row, a file covered only by a retired row, a row with empty registry
# fields, an enum typo, and a stale row. Needs python3 and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CHECK="${ROOT}/.github/actions/ai-inventory/check.py"
PATTERNS="${ROOT}/policies/ai/agent-config-patterns.txt"
FIX="${HERE}/fixtures/repo"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
run() {  # <name> <root> [args]; sets rc
  : > "${TMP}/$1.out"
  set +e
  GITHUB_OUTPUT="${TMP}/$1.out" GITHUB_STEP_SUMMARY="${TMP}/$1.summary" \
    python3 -I "${CHECK}" --root "$2" --patterns "${PATTERNS}" --output "${TMP}/$1.json" "${@:3}" > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
}
q() { jq -r "$2" "${TMP}/$1.json"; }

echo "== fixture repo: five errors, one warning"
run fx "${FIX}"
[ "${rc}" -eq 1 ] || fail "expected rc 1, got ${rc}: $(cat "${TMP}/fx.log")"
[ "$(q fx '.files | keys | join(",")')" = ".claude/agents/reviewer.md,.claude/settings.json,.cursor/rules.md,.github/workflows/gemini-triage.yml,.github/workflows/review-claude.yml,.mcp.json,AGENTS.md" ] || fail "matched files: $(q fx '.files | keys')"
[ "$(q fx '.files[".claude/agents/reviewer.md"] | join(",")')" = "Claude Code (developer)" ] || fail "** glob in a config path cell"
[ "$(q fx '.files[".mcp.json"] | join(",")')" = "Claude Code (developer)" ] || fail "multi-pattern cell"
[ "$(q fx '.files[".github/workflows/review-claude.yml"] | join(",")')" = "Claude review action" ] || fail "workflow row"
[ "$(q fx '.files[".cursor/rules.md"] | length')" = "0" ] || fail "uncovered file must have no owner"
grep -q '^::error title=ai-inventory::.cursor/rules.md: no inventory row covers it' "${TMP}/fx.log" || fail "uncovered error"
grep -q '^::error title=ai-inventory::.github/workflows/gemini-triage.yml: covered only by a retired row (Gemini triage)' "${TMP}/fx.log" || fail "retired-row error"
grep -q '^::error file=docs/ai-agents.md,line=8,title=ai-inventory::docs/ai-agents.md:8: Codex: "owner" is empty' "${TMP}/fx.log" || fail "empty owner error: $(grep Codex "${TMP}/fx.log")"
grep -q 'Codex: "kill switch" is empty' "${TMP}/fx.log" || fail "empty kill switch error"
grep -q 'Old copilot: "risk tier" is "lowish", expected one of high, low, medium' "${TMP}/fx.log" || fail "enum error"
grep -q '^::warning title=ai-inventory::docs/ai-agents.md:9: Old copilot: config path matches no file (stale row?)' "${TMP}/fx.log" || fail "stale warning"
[ "$(q fx '.errors | length')" = "5" ] || fail "error count $(q fx '.errors | length'): $(q fx '.errors')"
[ "$(q fx '.warnings | length')" = "1" ] || fail "warning count"
grep -q '^## AI agent inventory: 7 configuration file(s), 5 row(s), 5 error(s), 1 warning(s)' "${TMP}/fx.summary" || fail "summary heading: $(head -1 "${TMP}/fx.summary")"
# shellcheck disable=SC2016  # the backticks are literal markdown, not command substitutions
grep -q '^| `.cursor/rules.md` | \*\*none\*\* |' "${TMP}/fx.summary" || fail "summary marks the uncovered file"
# shellcheck disable=SC2016
grep -q '^| <name> | `<config path>` |' "${TMP}/fx.summary" || fail "row template in the summary"
[ "$(grep '^error-count=' "${TMP}/fx.out" | cut -d= -f2)" = "5" ] || fail "error-count output"

echo "== extra patterns and excludes"
mkdir -p "${TMP}/extra/.claude" "${TMP}/extra/docs" "${TMP}/extra/node_modules/.claude" && echo '{}' > "${TMP}/extra/.claude/settings.json" && echo '{}' > "${TMP}/extra/node_modules/.claude/settings.json" && echo 'x' > "${TMP}/extra/bot.yaml"
cat > "${TMP}/extra/docs/ai-agents.md" <<'EOT'
| Name | Config path | Provider | Class | Risk tier | Lifecycle state | Credential | Permitted tools and data classes | Write access to production | Human approval required | Owner | Kill switch | DPA on file |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Claude | `.claude/settings.json` | Anthropic | on-behalf-of | low | active | API key: K | Read; public | no | yes | team-x | revoke K; team-x; drilled 2026-10-01 | yes |
| Bot | `bot.yaml` | self-hosted | guardian | low | proposed | OIDC | none | no | yes | team-x | stop the workflow; team-x; not yet drilled | n/a |
EOT
run extra "${TMP}/extra" --extra-patterns "bot.yaml"
[ "${rc}" -eq 0 ] || fail "extra rc ${rc}: $(cat "${TMP}/extra.log")"
[ "$(q extra '.files | keys | join(",")')" = ".claude/settings.json,bot.yaml" ] || fail "extra pattern matched and node_modules excluded: $(q extra '.files | keys')"

echo "== this repository: no agent configuration, empty inventory, passes"
run self "${ROOT}" --exclude ".git,node_modules,tests"
[ "${rc}" -eq 0 ] || fail "self rc ${rc}: $(cat "${TMP}/self.log")"
[ "$(q self '.files | length')" = "0" ] || fail "this repo should match no agent config (tests excluded): $(q self '.files | keys')"
[ "$(q self '.rows | length')" = "0" ] || fail "empty inventory"

echo "== missing inventory or table is an error"
mkdir -p "${TMP}/none/.claude" && echo '{}' > "${TMP}/none/.claude/settings.json"
run none "${TMP}/none"
[ "${rc}" -eq 1 ] || fail "missing inventory must fail"
grep -q 'inventory .*docs/ai-agents.md does not exist' "${TMP}/none.log" || fail "missing inventory message"
mkdir -p "${TMP}/none/docs" && echo '| Name | Path |' > "${TMP}/none/docs/ai-agents.md"
run notable "${TMP}/none"
[ "${rc}" -eq 1 ] || fail "no-table rc ${rc}"
grep -q 'has no table with a "Config path" column' "${TMP}/notable.log" || fail "no-table error"

echo "all ai-inventory checks passed"
