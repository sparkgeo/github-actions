# Findings labels

Labels used to track security findings and exceptions in any Sparkgeo repo. The SLA rows and the workflow mapping are in [CONTRIBUTING.md § Findings and SLAs](../CONTRIBUTING.md#findings-and-slas); the exception form is [`.github/ISSUE_TEMPLATE/security-exception.yml`](../.github/ISSUE_TEMPLATE/security-exception.yml); the validation trigger form is [`.github/ISSUE_TEMPLATE/validation-trigger.yml`](../.github/ISSUE_TEMPLATE/validation-trigger.yml) and its rules are in [`docs/validation.md`](validation.md).

| Label | Colour | Meaning |
|---|---|---|
| `security-finding` | `D93F0B` | A finding from a CI scan gate, triaged into this issue. Always paired with one `sla:*` label. |
| `sla:secret` | `000000` | Secret / credential leak: revoke and rotate within 24 hours, every environment. |
| `sla:critical` | `B60205` | Critical: 48 hours in production, 7 days in non-production. |
| `sla:high` | `E99695` | High: 7 days in production, 30 days in non-production. |
| `sla:medium` | `FBCA04` | Medium: 30 days in production, 90 days in non-production. |
| `sla:low` | `C2E0C6` | Low: 90 days or next scheduled maintenance in production; tracked only in non-production. |
| `exception` | `5319E7` | An approved, time-boxed (90 days maximum) exception is open for this finding. Applied by the exception issue form. |
| `validation:high` | `D4C5F9` | A High-tier validation trigger: the control is validated within 72 hours of this issue opening. Applied by the validation trigger form. See [`docs/validation.md`](validation.md). |
| `validation:medium` | `E4E669` | A Medium-tier validation trigger: validated within 7 days. |
| `validation:miss` | `B60205` | A technique the controls neither prevented nor detected in a validation run. Always paired with `security-finding` and `sla:high`. |
| `outcome:fix` | `0E8A16` | Decision outcome: remediated. A control-change fix carries the re-validation result; a code fix carries the merged PR and the passing re-scan. SSVC *Act*. |
| `outcome:mitigate` | `1D76DB` | Decision outcome: a compensating control recorded as *prevented* under emulation, or every layer in the control decomposition recorded as prevented or detected. Finding stays open one row lower. SSVC *Attend*. |
| `outcome:monitor` | `5319E7` | Decision outcome: a detection rule confirmed to fire for the technique. Finding stays open and is re-reviewed each cycle. SSVC *Track\**. |
| `outcome:accept` | `BFD4F2` | Decision outcome: an approved exception is open (the `exception` label and form). Re-enters validation when the asset, the control, or the threat intelligence changes. SSVC *Track*. |
| `forensic-triage` | `000000` | A KEV-listed CVE giving total control on a publicly exposed asset. Assume the asset was reached before the patch: scope in 0–2 h, preserve evidence in 2–24 h before patching, contain in 6–24 h. Paired with `sla:critical`. |
| `ai-informational` | `C5DEF5` | Raised by a model (LLM review, AI test sweep, pentest agent) without a reproducer, an exploited status, or a traced path from input to sink. Starts no SLA clock. |

## Create the labels in a repo

One line, idempotent (`--force` updates colour and description if the label exists). Run it in the consuming repo, or with `--repo owner/name`:

```bash
for l in 'security-finding|D93F0B|Security finding from a CI scan gate; pair with one sla:* label' 'sla:secret|000000|Secret or credential leak: revoke and rotate within 24 h' 'sla:critical|B60205|Critical: 48 h production, 7 d non-production' 'sla:high|E99695|High: 7 d production, 30 d non-production' 'sla:medium|FBCA04|Medium: 30 d production, 90 d non-production' 'sla:low|C2E0C6|Low: 90 d or next maintenance; tracked only in non-production' 'exception|5319E7|Approved time-boxed security exception (90 d max)' 'validation:high|D4C5F9|High-tier validation trigger: validate within 72 h' 'validation:medium|E4E669|Medium-tier validation trigger: validate within 7 d' 'validation:miss|B60205|Technique missed in a validation run; pair with security-finding and sla:high' 'outcome:fix|0E8A16|Decision outcome: remediated (SSVC Act)' 'outcome:mitigate|1D76DB|Decision outcome: compensating control validated as prevented; open one row lower (SSVC Attend)' 'outcome:monitor|5319E7|Decision outcome: detection rule confirmed to fire; open, re-reviewed each cycle (SSVC Track*)' 'outcome:accept|BFD4F2|Decision outcome: approved exception open (SSVC Track)' 'forensic-triage|000000|KEV CVE with total control on a public asset: scope, preserve, contain before patching' 'ai-informational|C5DEF5|Model-raised finding without reproducer or traced path; no SLA clock'; do IFS='|' read -r n c d <<<"$l"; gh label create "$n" --color "$c" --description "$d" --force; done
```

## Reusing the exception form org-wide

GitHub serves issue forms from an organisation's `.github` repository to every repo that has no template of its own. To make the exception form available everywhere, copy `.github/ISSUE_TEMPLATE/security-exception.yml` from this repo into `sparkgeo/.github` at the same path. That repo does not exist yet; creating it is an org-admin task. Until then, copy the file into each consuming repo alongside the label script above.

## Monthly review queries

```bash
# Findings older than 14 days with no decision outcome (the plan's decision-coverage KPI)
gh issue list --label security-finding --state open --search "created:<2026-10-01 -label:outcome:fix -label:outcome:mitigate -label:outcome:monitor -label:outcome:accept"
# Findings past their window (adjust the date)
gh issue list --label security-finding --state open --search "created:<2026-09-01"
# Validation triggers past their deadline (72 h High, 7 d Medium; the deadline is in the issue body)
gh issue list --label validation:high --state open --search "created:<2026-10-11"
# Exceptions expiring: the expiry date is in the issue body; sort oldest first
gh issue list --label exception --state open --json number,title,createdAt --jq 'sort_by(.createdAt)[] | "\(.number)\t\(.createdAt[:10])\t\(.title)"'
```
