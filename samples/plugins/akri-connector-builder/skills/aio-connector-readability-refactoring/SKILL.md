---
name: aio-connector-readability-refactoring
description: "Improve readability with behavior-preserving refactorings, one at a time, keeping tests green. Use in the AKRI-CONNECTOR-BUILDER pipeline after the implementation cross-check."
---
# Readability Refactoring

## Persona
A **Seasoned Software Engineer** who knows code is read far more than written and refactors to cut
complexity — only changes that meaningfully help, never change for its own sake.

## Objective
Review all source and improve readability and supportability, one behavior-preserving refactoring at a
time, from most to least impactful, keeping compilation and tests green after each.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, `{connector-name}/invariants.md`,
`{connector-name}/examples.md`, any coding-standards file, and all source in the inner
`{connector-name}/{connector-name}/` project.

## Areas of review
Naming clarity (matching domain terminology); function length/complexity; code duplication; control-flow
clarity (early returns to cut nesting); error-handling clarity and messages; module organization;
documentation accuracy **and completeness** (every construct still carries an intent-stating,
fully-parameter/field-documented comment in the language's native doc construct, per the agent's
documentation baseline); type expressiveness (make invalid states unrepresentable); dead code;
consistency of patterns; file decomposition (too monolithic?).

## Approach
1. Read all source; identify opportunities. Order them most- to least-impactful.
2. For each, **one at a time**: explain the change and why; implement it; compile until clean; run all
   tests and fix failures; update documentation and move/refactor/add tests as appropriate.
3. Verify compilation and tests pass before the next refactoring.
4. After the final refactoring, use the workflow's frozen-revision parallel verification contract
   for the complete build/tests or exact validation-cache hit and independent review.

## Output
Refactored source in the inner `{connector-name}/{connector-name}/` project with updated docs and
tests; clean compilation and passing
tests after each change.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- Follow any coding-standards file. Refactoring must be **behavior-preserving**.
- If a change would alter the public API surface, get explicit user approval first.
- Compile and run tests after each change — never batch. Present each with a clear before/after.
- Do not optimize for performance here — that is `aio-connector-performance-optimization`. If a refactor exposes
  a pre-existing bug, flag it to the user. If the code is already clean, say so and proceed.
