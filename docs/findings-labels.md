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

## Create the labels in a repo

One line, idempotent (`--force` updates colour and description if the label exists). Run it in the consuming repo, or with `--repo owner/name`:

```bash
for l in 'security-finding|D93F0B|Security finding from a CI scan gate; pair with one sla:* label' 'sla:secret|000000|Secret or credential leak: revoke and rotate within 24 h' 'sla:critical|B60205|Critical: 48 h production, 7 d non-production' 'sla:high|E99695|High: 7 d production, 30 d non-production' 'sla:medium|FBCA04|Medium: 30 d production, 90 d non-production' 'sla:low|C2E0C6|Low: 90 d or next maintenance; tracked only in non-production' 'exception|5319E7|Approved time-boxed security exception (90 d max)' 'validation:high|D4C5F9|High-tier validation trigger: validate within 72 h' 'validation:medium|E4E669|Medium-tier validation trigger: validate within 7 d' 'validation:miss|B60205|Technique missed in a validation run; pair with security-finding and sla:high'; do IFS='|' read -r n c d <<<"$l"; gh label create "$n" --color "$c" --description "$d" --force; done
```

## Reusing the exception form org-wide

GitHub serves issue forms from an organisation's `.github` repository to every repo that has no template of its own. To make the exception form available everywhere, copy `.github/ISSUE_TEMPLATE/security-exception.yml` from this repo into `sparkgeo/.github` at the same path. That repo does not exist yet; creating it is an org-admin task. Until then, copy the file into each consuming repo alongside the label script above.

## Monthly review queries

```bash
# Findings past their window (adjust the date)
gh issue list --label security-finding --state open --search "created:<2026-09-01"
# Validation triggers past their deadline (72 h High, 7 d Medium; the deadline is in the issue body)
gh issue list --label validation:high --state open --search "created:<2026-10-11"
# Exceptions expiring: the expiry date is in the issue body; sort oldest first
gh issue list --label exception --state open --json number,title,createdAt --jq 'sort_by(.createdAt)[] | "\(.number)\t\(.createdAt[:10])\t\(.title)"'
```
