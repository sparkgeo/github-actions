# Findings labels

Labels used to track security findings and exceptions. The SLA rows and the workflow mapping are in [CONTRIBUTING.md § Findings and SLAs](../CONTRIBUTING.md#findings-and-slas); the exception request template is [`docs/templates/security-exception.yml`](templates/security-exception.yml).

**Private repos only.** A finding or exception issue names an unfixed vulnerability, where it runs and what is holding it back. Create these labels, and file these issues, only in a private repo: the org's private security tracker, or a consuming repo that is itself private.

| Label | Colour | Meaning |
|---|---|---|
| `security-finding` | `D93F0B` | A finding from a CI scan gate, triaged into this issue. Always paired with one `sla:*` label, added at triage. |
| `sla:secret` | `000000` | Secret / credential leak: revoke and rotate within 24 hours of detection, every environment. |
| `sla:critical` | `B60205` | Critical: 48 hours in production, 7 days in non-production. |
| `sla:high` | `E99695` | High: 7 days in production, 30 days in non-production. |
| `sla:medium` | `FBCA04` | Medium: 30 days in production, 90 days in non-production. |
| `sla:low` | `C2E0C6` | Low: 90 days or next scheduled maintenance in production; tracked only in non-production. |
| `exception-requested` | `D4C5F9` | An exception request, not yet approved. Applied by the exception template. |
| `exception-approved` | `5319E7` | Approved by a member of `@sparkgeo/security-team` other than the requester; time-boxed to 90 days. Applied by the approver. |

Approval is the label, not a comment. Only people with triage access can apply labels, so give it to `@sparkgeo/security-team` and not to every requester. The approver removes `exception-requested` when applying `exception-approved`.

## Create the labels in a repo

Idempotent (`--force` updates colour and description if the label exists). Set `R` to target another repo; leave it empty for the repo in the current directory. Works in bash and zsh.

```bash
R=""   # e.g. R=sparkgeo/security-tracker
args=(); [ -n "$R" ] && args=(--repo "$R")
for l in 'security-finding|D93F0B|Security finding from a CI scan gate; pair with one sla:* label' 'sla:secret|000000|Secret or credential leak: revoke and rotate within 24 h of detection' 'sla:critical|B60205|Critical: 48 h production, 7 d non-production' 'sla:high|E99695|High: 7 d production, 30 d non-production' 'sla:medium|FBCA04|Medium: 30 d production, 90 d non-production' 'sla:low|C2E0C6|Low: 90 d or next maintenance; tracked only in non-production' 'exception-requested|D4C5F9|Security exception request, not yet approved' 'exception-approved|5319E7|Security exception approved by security-team, 90 d max'; do IFS='|' read -r n c d <<<"$l"; gh label create "$n" --color "$c" --description "$d" --force "${args[@]}"; done
```

## Using the exception template

Copy `docs/templates/security-exception.yml` to `.github/ISSUE_TEMPLATE/` in a private repo, and run the label script there. Do not put it in the org's `sparkgeo/.github` repository: GitHub serves templates from there to every repo in the org, public ones included.

## Monthly review queries

Run in the private repo that holds the issues (or add `--repo`). Both list up to 500 open issues; raise `-L` if you have more.

Findings past their deadline. The issue creation date stands in for the triage date, and the production window is used (the stricter one):

```bash
gh issue list --label security-finding --state open -L 500 --json number,title,createdAt,labels --jq '
  {"sla:secret":1,"sla:critical":2,"sla:high":7,"sla:medium":30,"sla:low":90} as $days
  | .[]
  | ([.labels[].name | select(startswith("sla:"))][0]) as $sla
  | select($sla != null)
  | ((now - (.createdAt | fromdateiso8601)) / 86400 | floor) as $age
  | select($age > $days[$sla])
  | "\(.number)\t\($sla)\t\($age) days open (window \($days[$sla]))\t\(.title)"'
```

Approved exceptions by expiry date, soonest first, read from the template's "Requested exception expiry" field:

```bash
gh issue list --label exception-approved --state open -L 500 --json number,title,body --jq '
  map(. + {expiry: ((.body | capture("### Requested exception expiry\\s+(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})").d) // "unparsed")})
  | sort_by(.expiry)[]
  | "\(.number)\t\(.expiry)\t\(if .expiry != "unparsed" and .expiry <= (now | strftime("%Y-%m-%d")) then "EXPIRED" else "" end)\t\(.title)"'
```

Pending requests (`--label exception-requested`) are reviewed separately; they are not active exceptions.
