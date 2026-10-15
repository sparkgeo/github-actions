# Privacy impact assessment (template)

SecOps plan Step 36 Standard, section 5 (issue #121). Copy to `docs/pia/<activity>.md` in the repository, fill in every section, link it from the PR body, and request the privacy owner's review; the privacy review gate checks for the link, the `privacy-review` label and the owner's approval. One PIA per processing activity (`ropa.yml` id), updated when the activity changes.

```markdown
# PIA: <activity id from ropa.yml>

| | |
|---|---|
| Activity | `<ropa.yml id>` |
| Owner | <team or person> |
| Date | <YYYY-MM-DD> |
| Status | draft / reviewed / approved |
| Related PRs | #<n> |

## 1. Purpose

What the processing is for, in one paragraph a data subject would understand. Which product feature or client deliverable needs it.

## 2. Data categories and subjects

| Category (ropa.yml enum) | Fields | Subjects | Source (form, API, partner, derived) | Classification tier |
|---|---|---|---|---|
| location | lat/lon, timestamp | end-users | mobile app | confidential |

Special categories (Art. 9)? yes / no. Location histories of identifiable people count as Restricted.

## 3. Necessity and proportionality

Why each field is needed for the purpose; what was considered and rejected (coarser location, shorter retention, aggregation, pseudonymisation); the lawful basis and, for legitimate interests, the balancing test (link the LIA).

## 4. Flows

Where the data enters, is stored (inventory ids), is logged, and leaves (processors, DPAs, transfer mechanism). Paste or link the privado data-flow summary for the PR.

## 5. Retention and deletion

Retention per store (must match `retention.yml`), the mechanism that enforces it, and how a deletion or export request is served (DSAR harness, #122).

## 6. Risks

| Risk | Likelihood | Impact | Who is harmed |
|---|---|---|---|
| re-identification from location traces | medium | high | end-users |

## 7. Mitigations

Per risk: the control, who owns it, and the evidence (a retention policy in IaC, an access role, encryption with a customer-managed key, k-anonymity on outputs, a scrubbing middleware).

## 8. Residual risk and decision

What remains after mitigations; accept / reduce further / do not proceed; whether a DPIA consultation with a regulator is needed.

## 9. Sign-off

| Role | Name | Date |
|---|---|---|
| Author | | |
| Privacy owner | | |
| Security owner (Restricted tier) | | |
```

Keep the PIA short: a page for a small feature, three for a new product line. The gate reads the link, people read the content.
