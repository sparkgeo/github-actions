# External attack-surface scan

An attacker starts from the company name and finds whatever answers. The weekly scan ([`easm-scan.yml`](../.github/workflows/easm-scan.yml), issue #184, SecOps plan Step 31 Standard) does the same thing first and reconciles the result against what we expect to be public. The difference is the finding: an internet-facing host that matches no register record and no known host is **High**, validated within 72 hours under the [trigger table](validation.md#3-trigger-table), and claimed or removed.

## Scope and authorisation

Scanning is active probing. [`easm/scope.json`](../easm/scope.json) is the only list of what may be scanned:

| Field | Rule |
|---|---|
| `domains[]` | Registered domains we own or operate. Each needs an `owner` and an `authorisation`: `owned` for Sparkgeo's own registrations; for client-delivered infrastructure we run, a reference to the client's written authorisation (ticket or document). A client's own domains and accounts stay out until that reference exists |
| `cidrs[]` | Public ranges we hold; same `owner` and `authorisation` fields |
| `known_hosts[]` | Internet-facing hosts the asset register cannot name (the register lists cloud resources from plan output, not DNS names it did not create); each with an `owner` |
| `exclude[]` | Hosts never probed, whatever discovery finds |

`reconcile.py check-scope` runs first in the workflow and in CI (`tests/easm/run.sh`); an entry without owner or authorisation fails the job. Adding a client domain is a reviewed PR that cites the authorisation.

## Runner and egress

The scanner connects to the hosts it discovers, so `harden-runner` runs in audit mode and no allowlist applies. The MDR (Step 12) and the WAF (Step 34) must know the scanner's address so the run is not triaged as an attack, and GitHub-hosted runners have no fixed IP. Set the repository variable `EASM_RUNNER` to the label of a self-hosted runner (or a runner group behind a NAT) with a fixed egress IP, record that IP and a named owner in the MDR and WAF allowlists, and keep the variable unset only for dry runs from a GitHub-hosted runner.

Upstream hosts the job reaches besides the targets: `github.com` and `release-assets.githubusercontent.com` (pinned, checksum-verified ProjectDiscovery binaries; the register and the release), `pypi.org` and `files.pythonhosted.org` (`dnstwist`, hash-pinned), `crt.sh` (certificate transparency), and the passive sources `subfinder` queries without API keys.

## Stages

| Stage | What | Tool |
|---|---|---|
| Seed | `scope.json` domains and known hosts; every `exposure=public` resource and DNS record in the register (`asset-register-latest`, #116); every name ever certified under each domain (`crt.sh`) | `jq`, `curl` |
| Discover | Subdomains from passive sources; A, AAAA and CNAME resolution; HTTP on 80, 443, 8080, 8443 with title and technology; top 100 TCP ports (connect scan, rate-limited) | `subfinder`, `dnsx`, `httpx`, `naabu` |
| Assess | Exposed panels, misconfigurations, dangling-DNS takeovers and known CVEs, medium and above, rate-limited, non-intrusive template sets only | `nuclei` (`exposures`, `misconfiguration`, `takeovers`, `cves`) |
| Lookalike | Registered typo and homoglyph variants of each domain (Step 29) | `dnstwist --registered` |
| Reconcile | Join everything with the expected-public set; classify | [`reconcile.py`](../.github/actions/easm/reconcile.py) |
| Alert | One issue per finding, deduplicated by title | `gh` |
| Publish | `findings.json`, `unknown-assets.md`, `retired-candidates.md`, `public-assets.md`, `summary.md`, `SHA256SUMS` on `easm-latest` and `easm-YYYY-MM-DD` (26 dated tags kept) | `gh release` |

## Findings

| Kind | Severity | Issue labels | Meaning |
|---|---|---|---|
| `unknown-asset` | High | `security-finding`, `sla:high`, `validation:high` | Answers from the internet under a scoped domain, matches no register record and no known host. Claim it (add to `known_hosts` with an owner, or tag the resource `exposure=public` so the register lists it) or remove it |
| `takeover-candidate` | High | `security-finding`, `sla:high` | CNAME to a name that resolves to nothing (a released bucket, a deleted distribution) |
| `nuclei` | its own | `security-finding`, `sla:<severity>` | Template match on a live host |
| `lookalike-domain` | Medium | `security-finding`, `sla:medium` | A registered variant of a scoped domain; a takedown goes through the registrar |
| `retired-candidate` | informational | none | Expected public but no longer resolves; retire it from the register or `known_hosts` |

More than 3 unknown assets in one run also opens an inventory-review issue: onboarding skipped the inventory somewhere. The count per run is the plan's "unknown internet-facing assets" KPI; it should trend to zero.

## Quarterly attestation

`public-assets.md` lists every host that answered in the run with its owner and open ports. On the first run of each quarter the workflow opens `Public asset attestation YYYY-QN` with that list; the security owner reviews it, fixes ownership, and closes the issue as the attestation record. This is what CISA BOD 26-04 asks of federal agencies and what client questionnaires ask of us.

## Local run

```bash
python3 -I .github/actions/easm/reconcile.py check-scope --scope easm/scope.json
python3 -I .github/actions/easm/reconcile.py reconcile --scope easm/scope.json --out-dir /tmp/easm \
  --dnsx dnsx.jsonl --httpx httpx.jsonl --naabu naabu.jsonl --nuclei nuclei.jsonl --dnstwist dnstwist.json
```

`tests/easm/run.sh` exercises both commands against recorded discovery output. Results are Confidential (Step 23): they are a map of what the controls miss.
