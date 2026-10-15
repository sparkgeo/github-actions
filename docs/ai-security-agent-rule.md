# Security-agent rule

One rule for every model-driven agent that runs from CI in a Sparkgeo repository: the LLM diff reviewer (#181), the alert triage agent (#190), the AI-assisted UI tests (#182), the autonomous pentest agent (#188), the nightly LLM scanner (#105), the adversarial test suites (#106, #107). SecOps plan Step 26 Standard states it once; this page is the checklist a workflow author ticks before the agent gets a credential (issue #186). The registry it refers to is [`docs/ai-agents.md`](ai-agents.md), enforced by `ai-inventory-check.yml` (#102).

An agent holds a credential and acts. The models behind it read untrusted content. Each rule below closes one way that goes wrong, and names the workflow input or step that satisfies it so the check is mechanical.

## The rule

| # | Rule | Satisfied by |
|---|---|---|
| 1 | **Registered.** A row in `docs/ai-agents.md` before the configuration file lands: owner, class `guardian` (reviewers, testers, scanners, pentest agents) or `on-behalf-of`, risk tier, lifecycle state `proposed` until the kill switch is drilled, permitted tools and data classes | `ai-inventory-check.yml` fails the PR without the row |
| 2 | **Own key.** One credential per agent, issued at the Step 26 model gateway (or, until it exists, one API key per agent) with a token and spend budget and a rate limit; never a shared org key; stored as a repository or environment secret named in the row's Credential column | The workflow's `secrets:` block names that one secret; the row names it |
| 3 | **Read-only.** `permissions: contents: read` unless the agent opens a pull request; an agent-written PR passes the deterministic scanners, the test suite and a human review like any other change, never its own | The calling job's `permissions:`; the branch protection on `main` |
| 4 | **Trusted input only.** Runs on pull requests from the same repository by members, collaborators or owners; forks and external contributors skip with a one-line summary. Pull-request bodies, comments, issue text and web pages are untrusted and never passed as instructions; the task prompt names what the agent may act on | An `if:` on `github.event.pull_request.head.repo.full_name == github.repository` and `author_association`; a changed-files-only input |
| 5 | **Never gates.** `continue-on-error: true` on the step and never a required status check; the deterministic scanner and the tests gate the merge | The workflow README says "do not make this a required check"; the step's `continue-on-error` |
| 6 | **Evidence or informational.** A finding enters the Step 25 SLA table only with a reproducer, an `exploited` status or a traced path from input to sink. Otherwise it carries `ai-informational` and starts no clock. A model's downgrade of a Critical is a recommendation until a person records the outcome | The workflow labels its issues; the triage agent never dismisses an alert (#190) |
| 7 | **Browsing agents.** A dedicated test account and test tenant on staging, never a person's session or cookies; an ephemeral browser profile with state injected per run; outbound origins allowlisted at the proxy or egress (`harden-runner`, #83), not in the tool, because the tools' own allowlists are not a boundary; no write action against production; every page it reads is untrusted input; screenshots and traces are the audit log and are classified by what they show (Step 23) | `target-url` and `blocked-hosts` inputs; the egress allowlist; the trace artifact with short retention |
| 8 | **Sandboxed.** Code or shell tools run in an ephemeral container or microVM with no standing credentials; the tool's own host-shell integrations stay off in CI | The agent image pinned by digest; no `GITHUB_TOKEN` beyond `contents: read` inside the sandbox |
| 9 | **Measured.** Finding precision and patch acceptance recorded each quarter: a person labels confirmed findings `ai-review:true-positive` and dismissed ones `ai-review:false-positive`; targets from the plan are precision above 70 percent, AI patches merged without rework above 60 percent, reverts under 5 percent; recalibrate or drop the tool after two quarters below | The labels below; the quarterly count in the security meeting |
| 10 | **Killable.** The row's Kill switch column names the key to revoke, the account to disable and who may do it, drilled once against a non-production run before the lifecycle state becomes `active`, with the drill date in the row | `ai-inventory-check.yml` fails on an empty kill switch; the date in the row |

## Labels

Three labels, added to the findings label set (`docs/findings-labels.md`, #81) when that set lands; until then create them in the consuming repository:

```bash
for l in 'ai-informational|C5DEF5|Model-raised finding without reproducer or traced path; no SLA clock' 'ai-review:true-positive|0E8A16|AI finding confirmed by a person' 'ai-review:false-positive|E4E669|AI finding dismissed by a person'; do IFS='|' read -r n c d <<<"$l"; gh label create "$n" --color "$c" --description "$d" --force; done
```

## Applying it

Before adding a workflow that calls a model, copy the table into the PR description with each row ticked and the satisfying input named. The reviewer checks the row in `docs/ai-agents.md` and the `permissions:` block first; those two catch most mistakes. A workflow that cannot satisfy a row does not ship; a row that does not apply (a non-browsing agent and rule 7) is marked not applicable with the reason.

The `gemini-*` workflows this rule was first written against were removed from this repository in #133. The first reviewer that lands (#181) is the worked example and links back here from its README section.

## Why each rule exists

Rules 1, 2 and 10 are the plan's registry: a policy on an unregistered agent is a policy on nothing, and a kill switch never tested is a hypothesis. Rules 3, 5 and 6 keep the deterministic gate in charge: an agent that can merge or block on its own judgement is an unreviewed admin. Rule 4 is the prompt-injection boundary: none of the reviewer tools is hardened against a hostile PR body, and their READMEs say so. Rules 7 and 8 bound the blast radius of an agent that holds a session or a shell. Rule 9 is how the tool earns its place: without the precision count, noise and value look the same.
