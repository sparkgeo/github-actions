# Continuous security validation

How a deployed control is proven to still work: the rules every emulation run follows, when a run is owed, how its result is read, and how a finding fixed by a control change is closed. This is the CI-facing part of SecOps plan Step 40; the workflows are tracked under issue #174 (`sigma-lint.yml` #177, `stratus-red-team.yml` #178). Findings from a run follow [CONTRIBUTING.md § Findings and SLAs](../CONTRIBUTING.md#findings-and-slas); the labels are in [`docs/findings-labels.md`](findings-labels.md).

## 1. Rules of engagement

Tick every line before the first run and keep the ticked list with the results. A run without it is not evidence.

- [ ] Written scope approved by the security owner: which accounts, hosts, and techniques; which are excluded and why
- [ ] MDR or MSSP vendor notified in advance (the run must not be triaged as a real incident)
- [ ] Change ticket raised for the run window
- [ ] Only the non-destructive, reversible subset of the technique library; anything that modifies, encrypts, or removes data or credentials runs in an isolated lab only
- [ ] A tested stop procedure: who stops the run, how, and how clean-up is confirmed
- [ ] Results classified Confidential: they are a map of what the controls miss. Artifact retention short; private repository only
- [ ] For cloud runs: a dedicated non-production account, listed in the workflow's `allowed-account-ids`, carrying the production guardrails (GuardDuty or equivalent, alert routing, SCPs). A clean result from a lab policy is not evidence

## 2. Scope rule

Emulate against the production policy set that covers the most assets, in every region and account, not a lab policy or one hand-picked agent. Third-party point-to-point links and acquired environments are in scope. Autonomous agents start from several entry points matching the segmentation, never one agent with reach everywhere.

A segment excluded from live testing (operational technology, a client-owned network, a system whose exploit cannot be run safely) is written down with the reason and is covered by the control decomposition in section 5 instead.

## 3. Trigger table

Runs are owed on signals, not on the calendar. The scheduled runs are the floor. The clock starts when the signal lands as a ticket. One signal is one run and one ticket, however many assets it touches.

| Tier | Trigger | Validate within | Method | Owner |
|---|---|---|---|---|
| **High** | New internet-facing asset or open port from the external attack-surface scan (#184); KEV listing or CISA advisory naming a product in the asset register (#187); major production release or infrastructure-as-code change on a high-value asset; new public API or material API change; threat-intelligence spike on a technique or actor targeting the sector; regulatory change | 72 hours | Atomic Red Team or Caldera technique set for the advisory's TTPs; Stratus Red Team for cloud changes (#178); `nuclei` and DAST for the new endpoint; control decomposition where a live test is unsafe | Security owner |
| **Medium** | SIEM, EDR, WAF, or email-gateway rule or policy change; new control onboarded; pre-production deployment of a high-value service; MDR or vendor platform upgrade | 7 days | The rule's own test case (section 7) plus the techniques the control claims to cover; re-run of the last campaign against the changed control | Rule or control owner |
| **Low** | Routine maintenance, minor configuration change, non-production update | Next scheduled run | Scheduled weekly or monthly campaign | Security owner |

Open a [validation trigger](../.github/ISSUE_TEMPLATE/validation-trigger.yml) issue for every High or Medium signal; the form applies `validation:high` or `validation:medium`. At Baseline the High tier is run by hand when a KEV entry or an unknown asset names something in the register. The deadlines are the plan's proposed values until the first quarter of data calibrates them.

## 4. Reading a result

Record one outcome per technique:

| Outcome | Meaning | Counts toward coverage |
|---|---|---|
| **prevented** | The control blocked the action | Yes |
| **detected** | An alert reached a person inside the agreed window: 15 minutes for EDR, 1 hour for SIEM | Yes |
| **logged** | Evidence exists in a log but nobody was told | No. The cheapest gap to close: write the rule |
| **missed** | Nothing | No. A ticket with `validation:miss`, `security-finding`, and `sla:high` |

Report the prevention rate and the detection rate separately. A control that logs but never alerts scores zero.

## 5. Control decomposition

The written *Mitigate* procedure for a high-value asset or a CVE that cannot be exploited live:

1. Split the exploitation technique into the layers in front of the asset: perimeter firewall, IPS or WAF, EDR on the host, SIEM rule
2. Test each layer in isolation with a payload or a sample, and record it as prevented or detected (section 4)
3. The finding is **Mitigated** only when every layer assumed to cover it is recorded as prevented or detected. One layer at logged or missed leaves the finding open at its original row
4. Attach the per-layer results to the ticket; the downgrade expires when the next run no longer shows the layer as prevented

## 6. Re-validation gate

A finding fixed by a configuration, rule, or control change closes only after the technique is re-run and recorded as **prevented** or **detected**. The re-run result is linked on the ticket before it is closed. Code fixes close on the merged PR plus a passing re-scan; they do not need an emulation run.

The same gate applies to a compensating control cited in a [security exception](../.github/ISSUE_TEMPLATE/security-exception.yml): the control counts only with a *prevented* result attached.

## 7. Test-case schema

Every detection rule kept as code (Sigma, checked by `sigma-lint.yml`, #177) has one test case that names the technique that must fire it. Without a test case the rule is unproven and the lint fails.

File: `<tests-dir>/<rule-id>.yml`

```yaml
technique: T1078.004          # ATT&CK technique id the rule detects
source: stratus:aws.persistence.iam-create-admin-user
#   atomic:<test guid>        Atomic Red Team test, run by hand or by Invoke-AtomicRedTeam
#   stratus:<technique id>    Stratus Red Team technique, run by stratus-red-team.yml (#178)
#   manual                    Described in `steps`; run by a person
expect: detected              # detected or prevented; the outcome the next run must record
steps: |                      # manual sources only
  Create an IAM user with AdministratorAccess from a non-admin session.
```

`stratus-red-team.yml` reads `stratus:` sources to build its technique list; a rule whose test case has not fired in the last run is reported by the lint summary as stale.
