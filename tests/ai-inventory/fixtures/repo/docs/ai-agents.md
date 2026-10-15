# AI agents

| Name | Config path | Provider | Class | Risk tier | Lifecycle state | Credential | Permitted tools and data classes | Write access to production | Human approval required | Owner | Kill switch | DPA on file |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Claude Code (developer) | `.claude/settings.json`<br>`.claude/agents/**`<br>`.mcp.json` | Anthropic | on-behalf-of | medium | active | API key: ANTHROPIC_API_KEY (per developer) | Bash, Read, Edit; internal | no | yes | team-platform | revoke the developer's key in the Anthropic console; team-platform; drilled 2026-09-30 | yes |
| Claude review action | `.github/workflows/review-claude.yml` | Anthropic | guardian | low | active | API key: CLAUDE_REVIEW_KEY | read-only repository; internal | no | yes | bob@sparkgeo.com | delete CLAUDE_REVIEW_KEY; disable the workflow; bob; drilled 2026-10-01 | yes |
| Gemini triage | `.github/workflows/gemini-*.yml` | Google | autonomous | medium | retired | GitHub App: GEMINI_APP_ID | issues; internal | no | yes | team-platform | uninstall the App; team-platform; drilled 2026-08-15 | yes |
| Codex | `AGENTS.md` | OpenAI | on-behalf-of | medium | active | API key: OPENAI_API_KEY | shell; internal | no | yes |  |  | no |
| Old copilot | `.github/copilot-instructions.md` | GitHub | on-behalf-of | lowish | active | seat licence | editor; internal | no | yes | team-platform | remove the seat; team-platform; drilled 2026-07-01 | yes |
