# Open-source licence policy

SecOps plan Step 7 Baseline (issue #69): open-source licence scanning in CI. One policy, one allowlist, applied by `license-scan.yml` in every consuming repository so nobody copies the list by hand. The scanner is GitHub's dependency review (the [`dependency-review`](../.github/actions/dependency-review/action.yml) composite): a PR that adds a dependency whose licence is not on the allowlist fails.

## Classes

| Class | SPDX identifiers | Why |
|---|---|---|
| **Allowed** | MIT, MIT-0, Apache-2.0, BSD-2-Clause, BSD-3-Clause, 0BSD, ISC, Unlicense, CC0-1.0, Zlib, BSL-1.0, PSF-2.0, Python-2.0, PostgreSQL, Unicode-DFS-2016 | Permissive: redistribution in any form with attribution at most. No obligation reaches our own code or our customers' deployments. This is the default `allow-licenses` list. |
| **Allowed with notice** | MPL-2.0, LGPL-2.1-only, LGPL-2.1-or-later, LGPL-3.0-only, LGPL-3.0-or-later, EPL-1.0, EPL-2.0, CDDL-1.0, CDDL-1.1, OFL-1.1, CC-BY-4.0 | Weak copyleft or attribution licences: obligations stop at the file or library boundary (MPL, EPL, CDDL), apply only when the library is modified or statically linked (LGPL), or require a credit (OFL, CC-BY). Permitted when the library is used unmodified as a dependency and the repository keeps a third-party notice listing it. Opt in per repository with `allow-with-notice: true`. |
| **Denied** | AGPL-3.0, GPL-2.0, GPL-3.0, SSPL-1.0, BUSL-1.1, Elastic-2.0, Commons Clause, CC-BY-NC-*, CC-BY-SA-*, any proprietary or unknown licence (`NOASSERTION`, `NONE`, `LicenseRef-*`) | Strong or network copyleft reaches our code (GPL when linked, AGPL and SSPL when served over a network); source-available and non-commercial terms restrict what customers may do with a deployment; an unknown licence is a denied one until Legal reads it. |

GPL and AGPL **tools** that run in CI or on a developer machine and are not shipped with the product (a linter, a scanner, a build tool) are outside the policy: the licence attaches to redistribution, not use. Exempt such a package by package URL with `allow-dependencies-licenses` (for example `pkg:githubactions/owner/repo` or `pkg:pypi/some-cli`) and say why in the workflow file.

## Exceptions

A dependency outside the classes above needs a security exception issue (the `security-exception` template from #81) naming the package, the licence, where it ships, and the Legal reviewer; the exception is the purl added to `allow-dependencies-licenses`. Review it with the other exceptions.

## Gate in CI

```yaml
jobs:
  license-scan:
    if: github.event_name == 'pull_request' || (github.event_name == 'push' && github.ref == 'refs/heads/main' && github.event.before != '0000000000000000000000000000000000000000')
    permissions:
      contents: read
      pull-requests: write   # summary comment on failure
    uses: sparkgeo/github-actions/.github/workflows/license-scan.yml@<SHA>
    with:
      actions-ref: <SHA>            # same SHA as above
      # allow-with-notice: true     # adds the allowed-with-notice class; keep a third-party notice
      # allow-dependencies-licenses: pkg:githubactions/some/gpl-linter
      # fail-on-severity: high      # the same action also blocks vulnerable additions
```

The workflow needs the repository's dependency graph (on by default for public repositories; enable it under Settings → Code security for private ones). On push to the default branch it compares `github.event.before` with the pushed commit so the gate is visible without a PR.

## Fallback without the dependency graph

Where dependency review cannot run (a repository without the dependency graph, an ecosystem GitHub does not resolve, an air-gapped build), the same allowlist is applied locally with [`pip-licenses`](https://pypi.org/project/pip-licenses/) and [`license-checker-rseidelsohn`](https://www.npmjs.com/package/license-checker-rseidelsohn) from a pre-commit hook: copy [`examples/license.pre-commit-config.yaml`](../examples/license.pre-commit-config.yaml) into `.pre-commit-config.yaml` and run it in CI with `lint-precommit.yml`. Both tools read the installed packages, so the hook runs after `pip install` / `npm ci`. The list in that file is this policy's allowed class; keep it in step with this page when the policy changes.

## Related compliance

For a product with digital elements placed on the EU market, licence evidence is part of the third-party component due diligence in the EU Cyber Resilience Act map: [`cra.md`](cra.md).
