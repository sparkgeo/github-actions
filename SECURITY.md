# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities via the [GitHub Security Advisory](../../security/advisories/new) process:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with a description, affected versions, and reproduction steps.

Alternatively, email **info@sparkgeo.com** with the subject line `[SECURITY] sparkgeo/github-actions`.

## Disclosure Timeline

| Phase | Target |
|---|---|
| Acknowledgement | Within 2 business days of receipt |
| Initial assessment | Within 5 business days |
| Fix or mitigation | Within 30 days for high/critical; 90 days for moderate/low |
| Public disclosure | After fix is released, or 90 days from report (whichever comes first) |

We follow coordinated vulnerability disclosure. If we cannot ship a fix within 90 days, we will notify the reporter and agree on an extended timeline before any public disclosure.

## Scope

This repository contains reusable GitHub Actions composite actions. Vulnerabilities in scope include:

- Supply chain risks in pinned action SHAs or version references
- Script injection via user-controlled context variables in workflow or action YAML
- Overly permissive `GITHUB_TOKEN` permissions that could be exploited
- Secrets or credentials inadvertently exposed in workflow logs or artifacts
- Logic errors in composite actions that could cause callers to grant unintended access

Out of scope: vulnerabilities in third-party actions referenced by this repo (report those upstream). We will update our pinned SHA if a referenced action releases a security patch.

## Supported Versions

This repo does not use versioned releases. All consumers should pin to a specific commit SHA and update via Dependabot or Renovate (see `docs/approved-actions.md`). Only the current `main` branch is actively maintained.

## Security Contacts

- GitHub Security Advisory (preferred): https://github.com/sparkgeo/github-actions/security/advisories/new
- Email: info@sparkgeo.com
