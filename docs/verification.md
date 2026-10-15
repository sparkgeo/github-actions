# Program verification: the ladder, the map, the verdicts

SecOps plan Step 39 (issue #132, parent #124). Testing shows the presence of bugs; this step climbs a ladder from executable contracts and property tests, through symbolic execution and deductive verification, to model checking and machine-checked proof, on every pull request. The repository's `verify.yml` says which rung covers which path; every `verify-*.yml` reads it and reports in the same vocabulary. Two tiers are named here and never mixed: the plan's **Baseline / Standard / Advanced** (what a repository has adopted) and the review brief's **PR risk tier 0 / 1 / 2** (computed per PR from the paths it touches, `TIER_RULES`; it decides how much review a PR gets, not which rung is a gate).

## 1. The ladder

| Rung | What it is | Language workflow | Becomes a gate at |
|---|---|---|---|
| `boundary-contracts` | Validated types at the edges: `zod`/`valibot` schemas, Pydantic models, a trailing `assert`. For glue code this is the last rung. | #125, #127 | Baseline (presence, advisory) → Standard (mapped paths) |
| `contracts` | Executable pre- and postconditions on public functions: `icontract`, `deal`, PEP 316 docstrings. A checker needs a claim to refute; without one nothing above says anything. | #125 | Standard on high-risk paths (`strict-high-risk`) |
| `properties` | Property-based tests: Hypothesis, `rapid`/`quick`, `fast-check`; one property per acceptance criterion. | #125, #126, #127 | Baseline (tests run) → Standard (present on high-risk paths) |
| `fuzz` | Coverage-guided counterexample search: `go test -fuzz` per `Fuzz*` target, 45 s on a PR; the long run is #76 with the same corpus. | #126 | Baseline (a crasher blocks) |
| `symbolic` | CrossHair explores the paths a contract admits; a counterexample is a proof the contract is false. | #125 | Baseline (counterexample blocks) → Standard ("Not confirmed" blocks on high-risk paths) |
| `static` | The strictest type checker flags (`tsc --strict --noUncheckedIndexedAccess --exactOptionalPropertyTypes`, `mypy --strict`), `go vet`, `staticcheck`, `nilaway`, `errcheck`. | #125, #126, #127 | Baseline (`go vet`, `mypy`) → Standard (the rest; TypeScript errors with `strict-high-risk`) |
| `model-based` | Every path of an XState machine generated with `@xstate/graph` and executed. | #127 | Standard |
| `dafny` | Deductive verification of a shared core, compiled to Python, Go and JavaScript and drift-checked. | #128 | Standard |
| `gobra` | Deductive verification of pure Go packages. | #129 | Standard |
| `tla`, `alloy` | Model checking of a design: TLC over a spec with a sibling `.cfg`, Alloy over an assertion. The model, not the implementation. | #130 | Standard |
| `lean`, `kani` | Machine-checked proof (Lean 4 with Mathlib, `--wfail`); bounded model checking of Rust (`kani::proof`). | #131 | Advanced |

Refute before prove: Baseline tools search for counterexamples, so a counterexample blocks and a clean run is bounded confidence. Standard and Advanced tools prove, so "Not confirmed" and `sorry` fail there.

## 2. Reading verdicts

The wording is the brief's; the workflows print it verbatim.

| Tool | Verdict | Meaning | Do |
|---|---|---|---|
| CrossHair | `error: false when calling f(1) (which returns 1)` (counterexample) | a concrete input on which the stated contract is false; either the contract or the code is wrong, the PR decides which | fix one of them; blocks |
| CrossHair | `Confirmed over all paths` (exhausted) | CrossHair explored every symbolic path it could model: as strong as it gets short of a proof | nothing |
| CrossHair | `Not confirmed` | budget ran out or an opaque call (C extension, I/O) stopped the exploration; bounded confidence | raise `per_condition_timeout` (45 s) before `per_path_timeout` (3 s); most "not confirmed" are budget, not capability; or move the contract to a pure boundary |
| `crosshair diffbehavior` | `differs` | the refactored function returns something else than base on some input (shown) | decide whether the change was intended; advisory, `refactor` label only |
| `crosshair diffbehavior` | `agrees (within budget)` | no difference found in the budget | nothing |
| `crosshair diffbehavior` | `unsupported` | the symbolic tracer could not follow it (decorators, relative imports) | compare the undecorated implementation or skip |
| Go fuzz | a new file under `testdata/fuzz/<Fuzz name>/` (crasher) | a concrete input that panics or fails; replayed by every future `go test` | commit it with the fix; blocks |
| Go | `go vet` findings | static invariants broken in changed packages | fix; blocks |
| TypeScript | errors in changed files under the strictest flags | the file this PR touched does not hold under `--strict --noUncheckedIndexedAccess --exactOptionalPropertyTypes` (errors elsewhere are counted, not charged) | fix; advisory until `strict-high-risk`, then blocks |
| Dafny | `dafny verify` non-zero | a postcondition, invariant or termination proof failed for the Dafny source (not for hand-written code) | fix the proof or the spec; blocks at Standard |
| TLC | a trace | a sequence of states from the initial state to an invariant violation; the model is wrong or the design is | read the trace bottom-up; blocks at Standard |
| Lean 4 | build failure under `--wfail` | an unfinished proof (`sorry`) or a type error; `--wfail` turns the `sorry` warning into a failure | finish the proof; blocks at Advanced |
| Kani | `VERIFICATION:- FAILED` | a reachable panic or a failed harness within the bound | fix; blocks |
| Alloy | an instance | the analyzer found a model that violates the assertion within the scope | read the instance; blocks at Standard |

## 3. Where it pays off here, and where to stop

Worth every rung: CRS transforms, geometry predicates, tile and cell index arithmetic (XYZ, quadkey, H3, S2), antimeridian and pole handling, unit conversions, allocation and pricing. These are pure, small, and wrong in ways tests rarely find. Glue code (handlers, clients, config) gets `boundary-contracts` and nothing more: a validated type at the edge, then stop. The map encodes the decision: `risk: high` paths list the rungs, `risk: low` paths list `boundary-contracts` only.

## 4. Opaque boundaries

CrossHair, Dafny and Lean see Python, Dafny and Lean. A C extension (GEOS, PROJ, NumPy), cgo, or WASM is opaque: a contracted function that calls it is checked up to the call, and the census marks the function "opaque boundary", not failing. Put the contract at the language boundary: the pure function that prepares the input and interprets the output, with the extension call in between. Properties still run through the extension, so the pair (contract on the wrapper, property through the call) is the pattern.

## 5. `verify-brief.yml`, `review-brief.yml` and these workflows

The plan keeps two self-contained reference workflows beside each other, uncommitted and configured by `env` (`HIGH_RISK_GLOBS`, `CROSSHAIR_PER_PATH`, `CROSSHAIR_PER_CONDITION`, `STRICT_HIGH_RISK`): `verify-brief.yml` (one job, every rung, one rolling comment, gate last) and `review-brief.yml` (lint, architecture, coverage, threat model, PR risk tier, mutation job). The workflows here decompose the verification brief into reusable, SHA-pinned pieces with the same verdicts, budgets and gate rules. A project runs one form or the other, not both. Shared conventions kept: `artifacts/` layout with `status/<tool>` exit codes and `summary.json` (schema in [`policies/verification/summary.schema.json`](../policies/verification/summary.schema.json)); one rolling PR comment via `gh pr comment --edit-last --create-if-none`; SARIF upload for inline annotations (`crosshair.counterexample` error, `crosshair.not-verified` note); the gate runs last so a red build arrives with its explanation; `STRICT_HIGH_RISK` semantics (uncontracted high-risk functions and TypeScript errors advisory until flipped); raw artefacts 30 days. The brief's fallback globs are the default here when `verify.yml` is absent, so adoption needs no config on day one:

```text
**/auth/** **/permissions/** **/billing/** **/payment*/** **/pricing/** **/crypto/** **/*secret* **/*token*
**/geometry/** **/geom/** **/crs/** **/projection*/** **/transform*/** **/tiles/** **/tile*/** **/index*/** **/h3/** **/s2/** **/quadkey*
```

### 5.6 Models: `verify-models.yml` (#130)

TLA+ with TLC follows the brief: every `.tla` with a sibling `.cfg` (no `.cfg`, skipped), `tlc2.TLC -workers auto -config <cfg>` under `timeout 480`. It differs in two places: the jar is `tla2tools.jar` v1.7.4, checked against a recorded SHA-256 (the brief fetches `releases/latest`), and it runs on a pinned Temurin 21. Apalache v0.62.3 (`use-apalache`) checks the same spec symbolically up to `--length` steps. It needs `\* @type:` annotations on constants and variables, which TLC ignores. Alloy 6.2.0 runs every `check` and `run` in each `.als`:

| Result | Means | Gate |
|---|---|---|
| TLC invariant or property violated, deadlock | a reachable behaviour breaks the claim; the trace (state, action, changed variables) is in the comment | blocks |
| TLC time out | the state space did not fit in 480 s; shrink the constants in the `.cfg` | blocks |
| Alloy `check` with an instance | a counterexample within the scope; the instance is in the comment | blocks (unless `expect 1`) |
| Alloy `run` with no instance | the facts admit nothing, so every `check` holds vacuously | blocks (unless `expect 0`) |

Name each action (`Retry == \E k \in Keys : Send(k)`) rather than writing it inline in `Next`, so the trace says which step happened. A protocol that ends needs an explicit terminal step (`Done == ... /\ UNCHANGED vars`), or TLC reports the end as a deadlock.

**Model-to-code mapping.** A spec's `verify.yml` entry names the implementation it describes in `covers`:

```yaml
- glob: specs/IdempotentRetry.tla
  risk: high
  rungs: [tla]
  covers: [internal/queue/worker.go, internal/queue/dedup.go]
```

The workflow runs a spec when the spec, its `.cfg` or any covered file changes. When covered code changes and the spec does not, the comment asks the reviewer to confirm the model still matches. Keep specs under `specs/`, one protocol per module, with constants small enough for TLC to finish (two or three keys, three retries).

**Review checklist** (spec PRs and covered-code PRs):

- The invariant states the acceptance criterion in the issue, not a weaker property that happens to hold.
- Every action in the code has an action in the spec, including failure paths (drop, duplicate, reorder, crash and restart).
- The `.cfg` constants are large enough to reach the interesting interleavings (at least two clients or keys, at least two retries).
- Alloy: each `check` has a `run` that shows the facts admit an instance; scopes are stated.
- A covered-code change that adds a state, message or retry path changes the spec in the same PR.

## 6. The map: `verify.yml`

Schema: [`policies/verification/verify.schema.json`](../policies/verification/verify.schema.json); example with all three languages and the cross-language tools: [`examples/verify.yml`](examples/verify.yml). One entry per path glob: `risk` (`high`, `medium`, `low`), `rungs` (lowest first), `tool` (inferred from the extension when absent), `targets` for Dafny compile targets, `covers` for the implementation globs a model stands for, `budget` overrides. `verify-map.yml` validates the file, resolves the changed files to their entries (longest glob wins) or to the fallback, and writes `verify-map.json` (`files`, `mapped`, `bare_high_risk`, `by_tool`) for the other workflows. A changed high-risk path with no rung is a warning at Baseline and fails with `strict-high-risk`; an implementation change under a model's `covers` without a change to the model is a warning.

## 7. `summary.json` and evidence

Each `verify-*.yml` emits the fields it owns from the brief's `summary.json` (others `null`, `tool` set) so a combined brief is rebuilt by taking the non-null value per field; the gate rules are in the schema's description. Evidence per plan tier:

| Tier | What is kept | For how long | Who asks for it |
|---|---|---|---|
| Baseline | `summary.json`, SARIF, crashers, the rolling comment | 30 days (the brief's value, the same window as the findings SLA for Medium in production, #81) | the PR reviewer |
| Standard | Baseline plus `verify-map.json`, Dafny and TLC logs, compiled Dafny targets, mutation reports | 90 days (the Low SLA window; one release cycle) | SOC 2 CC8.1 change management: the change, the review, the test evidence |
| Advanced | Standard plus Lean build logs and the proof sources at the merged commit, as a release artefact | 400 days (annual audit window, as the DSAR evidence, #122) | NIST SSDF PW.8 (verify code to identify vulnerabilities); DO-178C/DO-333 formal methods supplements where a client requires them: the proof, the tool version, the environment |

The merged commit plus the run's artefacts is the evidence; nothing is copied into a document by hand.

## 8. Mutation testing

Mutation scores say whether the properties would notice a wrong implementation. `mutmut` (#125), `gremlins` (#126) and Stryker (#127) run at Standard on mapped modules, advisory first; set `mutation-threshold` once the baseline is known (80 % on high-risk modules is the plan's figure). The test parent (#59) owns coverage and the unit test gates; mutation sits here because it measures the verification rungs, not the suite size.

## 9. PR template section

Add to `.github/PULL_REQUEST_TEMPLATE.md`; `verify-map.yml` with `require-table: true` (Standard) fails when mapped paths changed and the table is missing or empty:

```markdown
## Verification

Each acceptance criterion cites the contract, property, model or proof that covers it.

| Acceptance criterion | Covered by | Where |
|---|---|---|
| <criterion> | contract / property / fuzz target / Dafny lemma / TLA+ invariant / Lean theorem | `path:line` |
```

## Consuming

```yaml
jobs:
  verify-map:
    permissions:
      contents: read
    uses: sparkgeo/github-actions/.github/workflows/verify-map.yml@<SHA>
    with:
      actions-ref: <SHA>      # same SHA as above
      # require-table: true   # Standard tier
      # strict-high-risk: true
```
