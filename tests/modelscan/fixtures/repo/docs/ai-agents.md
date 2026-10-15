# AI agents and MCP servers

| Name | Config path | Provider | Class | Risk tier | Lifecycle state | Credential | Permitted tools and data classes | Write access to production | Human approval required | Owner | Kill switch | DPA on file |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Claude Code (developer) | `.mcp.json` | Anthropic | on-behalf-of | low | active | API key: ANTHROPIC_API_KEY | Read; public | no | yes | team-x | revoke key; team-x; drilled 2026-10-01 | yes |
| Old bot | `bots/old.yaml` | self-hosted | autonomous | low | retired | none | none | no | yes | team-x | removed | n/a |
