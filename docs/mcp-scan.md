# MCP server and skill scan

SecOps plan Step 26 (issue #103): MCP servers and skills are untrusted supply chain. They are **pinned by version and hash, scanned before registration and re-reviewed on update**, and taken only from a reviewed list. `mcp-scan.yml` is the PR gate; [`policies/ai/mcp-allowlist.json`](../policies/ai/mcp-allowlist.json) is the reviewed list; `.mcp-scan.lock` in each repository is the hash pin.

## Why

An MCP server delivers its tool descriptions straight into the model context. A malicious or compromised server can hide instructions in a description (tool poisoning), impersonate another server's tools (cross-origin escalation) or change a description after it was approved (rug pull). A skill file is the same thing in Markdown. The scan reads the repository's MCP configuration, connects to every declared server, records a hash of what it serves, and fails the PR when a server is not on the reviewed list, is not at its pinned version, or serves something other than what was reviewed.

## What runs

| Step | Tool | Egress |
|---|---|---|
| Inspect | `snyk-agent-scan inspect --json` (the former invariantlabs `mcp-scan`, pinned to 0.6.8) over the config files | the declared servers only; descriptions stay on the runner |
| Check | [`check.py`](../.github/actions/mcp-scan/check.py): allowlist, lockfile, skill hashes, fail-on gate | none |
| Analyse (`local-only: false` only) | `snyk-agent-scan scan --json` | sends every tool, prompt and skill description to `api.snyk.io` for prompt-injection, untrusted-content, private-data and destructive-capability scoring |

`local-only` defaults to `true` because tool descriptions name internal systems. Turn it off per repository when the Snyk analysis is wanted and the descriptions may leave the runner; `fail-on` then sets the band that fails the job (scores out of 1000: `low` 1, `medium` 300, `high` 600).

Both modes pass `--dangerously-run-mcp-servers`: the scanner **starts every stdio server the configuration declares** (`npx`, `uvx`, `docker`, a repo script) to read its descriptions. Call the workflow on trusted branches only, never from `pull_request_target`, and never in a job that holds secrets.

## Allowlist

One entry per reviewed server, keyed by the server name used in the configuration. A declared server must match an entry on every field:

```json
{
  "servers": [
    {
      "name": "filesystem",
      "source": "npm:@modelcontextprotocol/server-filesystem",
      "version": "2025.8.21",
      "command": "npx -y @modelcontextprotocol/server-filesystem@2025.8.21 /workspace",
      "hash": "sha256:…",
      "reviewed": "2026-10-14",
      "reviewer": "ms280690"
    },
    {
      "name": "github",
      "source": "https://api.githubcopilot.com/mcp/",
      "version": "2026-09",
      "url": "https://api.githubcopilot.com/mcp/",
      "hash": "sha256:…",
      "reviewed": "2026-10-14",
      "reviewer": "ms280690"
    }
  ],
  "skills": [
    {"path": ".claude/skills/deploy/SKILL.md", "source": "this repository", "version": "1", "hash": "sha256:…", "reviewed": "2026-10-14", "reviewer": "ms280690"}
  ]
}
```

Rules, each an error:

- a declared server with no entry of that name (unknown server);
- a stdio server whose `command` plus `args` differs from the pinned `command`, or a remote server whose `url` differs from the pinned `url`;
- an entry with no `version`; a server that reports a `serverInfo.version` other than the pinned one; a server run through `npx`, `uvx`, `pipx`, `bunx`, `pnpx` or `docker` whose command does not contain the pinned version (a floating `npx -y pkg` resolves to whatever is published today);
- a server the scanner could not reach: its hash cannot be verified;
- a hash that differs from the lockfile or from the entry (next section);
- a skill or plugin manifest (`.claude/skills/*/SKILL.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, or the `skills` input) with no entry by path.

The bundled list is the org list. A repository that needs its own passes `allowlist-path`; it then owns the review of every entry in it.

## Lockfile: `.mcp-scan.lock`

The hash is sha256 over the canonical JSON of the server's tools, prompts, resources and resource templates as served (null fields dropped), or over the bytes of a skill file. The lock records it per `config path::server name` and per skill path:

```json
{
  "servers": {".mcp.json::filesystem": "sha256:…"},
  "skills": {".claude/skills/deploy/SKILL.md": "sha256:…"},
  "version": 1
}
```

A changed hash fails the PR until the lock **and** the allowlist entry carry the new value: that is the re-review on update. Nobody updates the lock in CI; the reviewer does it after reading what changed:

```bash
pipx run --spec snyk-agent-scan==0.6.8 snyk-agent-scan inspect --json --dangerously-run-mcp-servers --no-skills .mcp.json > /tmp/inspect.json
python3 -I .sparkgeo-github-actions/.github/actions/mcp-scan/check.py --root . --inspect /tmp/inspect.json \
  --allowlist .sparkgeo-github-actions/policies/ai/mcp-allowlist.json --write-lock
```

Commit the lock with the allowlist change in the same PR. A lock entry for a server or skill that is no longer declared is an error too, so the lock never carries approvals for things that left.

## Adding a server

1. Open a PR against this repository that adds the allowlist entry: name, source, pinned version, exact command line or URL, hash from a local inspect run, reviewer and date. The review of that PR is the registration review (Step 26: scanned before registration).
2. In the consuming repository, declare the server at exactly that command line or URL, run the lock update above, and commit `.mcp-scan.lock` with the configuration.
3. The server also needs a row in `docs/ai-agents.md` (the agent registry, #102); `ai-inventory-check.yml` fails the PR without one.

## Consuming

```yaml
jobs:
  mcp-scan:
    permissions:
      contents: read
    uses: sparkgeo/github-actions/.github/workflows/mcp-scan.yml@<SHA>
    with:
      actions-ref: <SHA>       # same SHA as above
      # config-paths: .mcp.json,.vscode/mcp.json   # empty auto-detects
      # local-only: false      # send descriptions to Snyk and gate on fail-on
      # fail-on: medium
```

Auto-detection covers `.mcp.json`, `mcp.json`, `.vscode/mcp.json`, `.cursor/mcp.json`, `.gemini/settings.json`, `opencode.json` and `**/mcp-config*.json` to depth four. The job summary lists every server and skill with its hash and status, the analysis findings when `local-only` is off, and every error; errors are also PR annotations.

## Tested

[`tests/mcp-scan/run.sh`](../tests/mcp-scan/run.sh) runs the scanner against a fixture repository with one stdio and one Streamable HTTP server ([`server.py`](../tests/mcp-scan/fixtures/server.py), standard library), then checks the happy path, a changed tool description, an edited and a removed skill, each allowlist rule, `update-lock`, and the three `fail-on` bands over a recorded scan response. The CI job runs it with egress blocked except PyPI and GitHub, which is also the proof that `local-only` reaches nothing else.
