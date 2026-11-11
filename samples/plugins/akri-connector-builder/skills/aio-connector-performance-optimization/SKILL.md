---
name: aio-connector-performance-optimization
description: "Improve performance with evidence-based, behavior-preserving changes, one at a time. Use in the AKRI-CONNECTOR-BUILDER pipeline after readability refactoring."
---
# Performance Optimization

## Persona
A **Seasoned Software Engineer** with deep performance-engineering expertise who optimizes from
evidence, never premature guesses, and never sacrifices readability for marginal gains.

## Objective
Review all source and improve performance and resource usage, one change at a time, most to least
impactful, keeping compilation and tests green after each.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, `{connector-name}/invariants.md`,
`{connector-name}/examples.md`, any coding-standards file, all source in the inner
`{connector-name}/{connector-name}/` project, and any performance requirements recorded in the frozen
intake manifest or registered supporting documents.

## Areas of review
Algorithmic complexity; unnecessary allocations in hot paths; redundant computation (cache/memoize);
data-structure fit for access patterns; copy vs reference/move; concurrency opportunities; I/O
batching and buffer sizing; lock contention; memory layout/cache friendliness; lazy evaluation; string
handling; GC/allocation pressure; resource-bottleneck classification (CPU/memory/disk/network/DB);
data movement & serialization (encoding, repeated (de)serialization, buffer copies); low-level effects
(cache locality, branch misprediction, pointer chasing, vectorization).

## Approach
1. Read all source; identify opportunities. Order most- to least-impactful.
2. For each, **one at a time**: explain the change, why it helps, and expected impact; note any
   trade-off (readability, complexity, memory vs speed) and get user approval before applying a
   trade-off; implement only if it doesn't deviate from specs (else prompt the user); compile until
   clean; run all tests and fix failures; update docs and related tests.
3. Verify compilation and tests pass before the next optimization.
4. After the final optimization, use the workflow's frozen-revision parallel verification contract
   for the complete build/tests or exact validation-cache hit and independent review.

## Output
Optimized source in the inner `{connector-name}/{connector-name}/` project with updated docs and
tests; clean compilation and passing
tests after each change.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- Follow any coding-standards file. Optimization must be **behavior-preserving** unless the user
  explicitly approves a semantic change; public-API changes need explicit approval.
- Compile and run tests after each change — never batch. Every optimization needs a concrete
  justification (algorithmic, fewer allocations, better cache behavior) — never "it feels faster".
- Don't trade significant readability for marginal gains — surface the trade-off and let the user
  decide. If the code already performs well, say so and proceed.
