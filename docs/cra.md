# EU Cyber Resilience Act: applicability and evidence map

Regulation (EU) 2024/2847, the Cyber Resilience Act (CRA), is EU product-security law for "products with digital elements". Its Article 14 reporting obligations apply from 11 September 2026. The remaining obligations apply from 11 December 2027: security by design and by default, vulnerability handling, an SBOM for the product, security updates for the support period, technical documentation, and conformity assessment with CE marking.

This page maps those obligations to the workflows in this repository (issue #235), following the compliance reference in the SecOps plan (sparkgeo/systeam-home). It is not legal advice. Where a product's scope is in doubt, confirm it with counsel before relying on this page.

## Does it apply to the project?

Answer the plan's Appendix A question first: **do we place a product with digital elements on the EU market?**

| In scope | Generally not in scope |
|---|---|
| Installable software, such as a desktop plug-in or a QGIS extension sold or distributed commercially | A hosted SaaS service delivered to a client |
| An on-premises server package | |
| A mobile app | |
| An SDK or library sold or distributed commercially; firmware | |
| The remote data processing a product above depends on | |

A hosted service is in scope when it is the remote data processing behind a product that is. If the answer is no, the rest of this page does not apply. The CRA applies to manufacturers, importers and distributors of such products in the EU.

## Obligation-to-workflow map

Turn these on for every repository that builds the in-scope product. Rows that point at an issue are still in review and not yet on `main`.

| CRA obligation | Evidence | Workflow / issue |
|---|---|---|
| SBOM for the product | CycloneDX SBOM per release, attached to the release | `sbom-generate.yml` ([#62](https://github.com/sparkgeo/github-actions/issues/62)) |
| Vulnerability handling; no known exploitable vulnerabilities at release | Scan gates on every PR and release, triage records with SLA labels | `sbom-scan.yml` ([#63](https://github.com/sparkgeo/github-actions/issues/63)), `container-scan.yml` ([#14](https://github.com/sparkgeo/github-actions/issues/14)), `dep-scan-app.yml` ([#5](https://github.com/sparkgeo/github-actions/issues/5)), finding labels and SLA ([#81](https://github.com/sparkgeo/github-actions/issues/81), [#61](https://github.com/sparkgeo/github-actions/issues/61)) |
| Vulnerabilities communicated to users | VEX statements beside the SBOM | [#232](https://github.com/sparkgeo/github-actions/issues/232) |
| Integrity of updates and of the build | Build provenance, signed SBOM and signed images | `build-provenance.yml` ([#64](https://github.com/sparkgeo/github-actions/issues/64)), `container-sign.yml` and `container-verify.yml` ([#15](https://github.com/sparkgeo/github-actions/issues/15)) |
| Coordinated vulnerability disclosure and a contact point | `SECURITY.md` and `/.well-known/security.txt` in each product repository and site | Plan Step 20; no CI issue. This repository's own policy is [`SECURITY.md`](../SECURITY.md) |
| Security updates for the support period | Dependency update PRs; runtime end-of-life findings | `renovate.yml` ([#86](https://github.com/sparkgeo/github-actions/issues/86)), Dependabot ([#87](https://github.com/sparkgeo/github-actions/issues/87)), `eol-check.yml` ([#230](https://github.com/sparkgeo/github-actions/issues/230)) |
| Due diligence on third-party components | Malicious-package and reputation gates, supplier SBOM intake | `malicious-package-check.yml` ([#229](https://github.com/sparkgeo/github-actions/issues/229)), `dependency-reputation.yml` ([#111](https://github.com/sparkgeo/github-actions/issues/111)), [#233](https://github.com/sparkgeo/github-actions/issues/233); licences: [`license-policy.md`](license-policy.md) ([#69](https://github.com/sparkgeo/github-actions/issues/69)) |

## Reporting clocks

These apply to an actively exploited vulnerability in the product, or a severe incident affecting its security. Reports go through ENISA's [Single Reporting Platform](https://digital-strategy.ec.europa.eu/en/policies/cra-reporting).

| Report | Deadline |
|---|---|
| Early warning | Within 24 hours of becoming aware |
| Notification | Within 72 hours of becoming aware |
| Final report, actively exploited vulnerability | Within 14 days of a fix or mitigation being available |
| Final report, severe incident | Within one month of the notification |

The clocks belong to the incident response plan's notification checklist (plan Step 22), which this repository does not own. The workflows here supply the inputs: the SBOM shows which releases contain the component, VEX records which are affected, and the finding issue carries the timeline.

## Retention

The CRA asks manufacturers to keep the technical documentation for ten years after the product is placed on the market, or for the support period if that is longer. Workflow artefacts do not last that long. The 400-day evidence tier in `docs/verification.md` ([#132](https://github.com/sparkgeo/github-actions/issues/132)) also falls short. **Release assets are the record of truth**: attach the SBOM, VEX, provenance and scan summaries to each release, and keep releases for the support period.

## NIS2

NIS2 (Directive (EU) 2022/2555) places obligations on essential and important entities, not on the firm directly. It reaches the firm through EU clients' supplier-security requirements. The same evidence answers their questionnaires: SBOM, VEX, provenance, scan gates and the disclosure policy.
