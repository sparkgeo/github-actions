# AI agents and MCP servers

The agent registry for this repository (SecOps plan Step 26, issue #102). Every file that configures an AI agent, assistant or MCP server, matched by [`policies/ai/agent-config-patterns.txt`](../policies/ai/agent-config-patterns.txt), has one row here, and `ai-inventory-check.yml` fails the PR when it does not. Nothing gets a credential until it is on this list; the kill switch is written before the first run and drilled once.

## Columns

| Column | Values |
|---|---|
| Name | Short name used in issues and the kill-switch drill |
| Config path | Glob(s) the row covers, relative to the repository root; several separated by `<br>` |
| Provider | Anthropic, Google, OpenAI, GitHub, self-hosted (model and gateway) |
| Class | `on-behalf-of` (acts as the user who invoked it), `autonomous`, `orchestrator` (runs sub-agents, list them in Permitted tools), `guardian` (reviews, tests, scans; never changes production) |
| Risk tier | `low` (read-only, public or internal data), `medium` (writes to the repository or reads confidential data), `high` (reaches production, secrets, or restricted data) |
| Lifecycle state | `proposed`, `active`, `suspended`, `retired` (a retired row must match no file) |
| Credential | GitHub App, OIDC, or API key, and the secret name; never a shared org key |
| Permitted tools and data classes | What it may call and the highest data class it may read |
| Write access to production | `yes` / `no` |
| Human approval required | `yes` / `no`: a person approves each production-affecting action |
| Owner | `team-<name>` or `<user>@sparkgeo.com` |
| Kill switch | Which key to revoke, which account to disable, who may do it, and the date it was last drilled |
| DPA on file | `yes` / `no` / `n/a` for the provider |

## Inventory

| Name | Config path | Provider | Class | Risk tier | Lifecycle state | Credential | Permitted tools and data classes | Write access to production | Human approval required | Owner | Kill switch | DPA on file |
|---|---|---|---|---|---|---|---|---|---|---|---|---|

This repository runs no AI agent today. The Gemini CLI review, triage and plan-execute workflows were removed in #133; their rows went with them. Add a row before adding a configuration file.

## Adding an agent

1. Add the row with every column filled; `lifecycle state: proposed` until the kill switch has been drilled once.
2. Register the credential at the Step 26 gateway or as a repository secret named in the Credential column; one key per agent.
3. Add the configuration file; the check now passes.
4. Follow the [security-agent rule](ai-security-agent-rule.md) (issue #186) for reviewers, testers and pentest agents: copy its table into the PR with each row ticked.
