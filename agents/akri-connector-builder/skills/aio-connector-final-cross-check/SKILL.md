---
name: aio-connector-final-cross-check
description: "Audit source against all specs after refactoring and optimization. Use before connector metadata authoring, security review, and local validation in the AKRI-CONNECTOR-BUILDER pipeline."
---
# Final Cross-Check Alignment

## Persona
A **Seasoned Software Engineer** performing the final audit after refactoring and optimization — the
last line of defense before the code is complete.

## Objective
Re-compare the source against all specifications to ensure readability refactoring and performance
optimization introduced no **behavioral regressions**, **specification drift**, **missing
functionality**, **incorrect logic**, or **documentation staleness**. Resolve each issue one at a
time, most critical first.

## When to run
Start this skill immediately after Performance Optimization completes. Announce the phase with the
required progress banner, but **do not ask the user whether to perform the final cross-check or wait
for confirmation before starting it**.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents,
`{connector-name}/invariants.md`, `{connector-name}/examples.md`, and all source in the inner
`{connector-name}/{connector-name}/` project.

## Approach
Require an explicit ADR provenance review after optimization: every device/asset/data-operation
value must trace from an ADR field through the SDK observation, parser, resource-reference-keyed
state, and protocol call. Apply the agents' ADR-sourced configuration baseline. A read of any
non-AIO file from `CONNECTOR_CONFIGURATION_MOUNT_PATH`, an invented side channel, or a global
startup configuration is a blocker, even when unit tests pass. Recheck ADR-shaped fixtures,
SDK update/delete handling, resource-scoped invalid-configuration status/health, and the real
AIO-only zero-device startup test before attesting `adr-sourced-configuration`.

1. **Compare systematically:** protocol specifications → code, confirmed intake requirements → code,
   decisions → code, and invariants → code (all still upheld?). Recheck architectural boundaries,
   public APIs, and operator-facing behavior against those inputs and the selected SDK contracts.
2. **Prioritize** most critical (behavioral regression, security gap) to least (documentation staleness).
3. **One issue at a time** (Playbook §2): name the affected requirement (with ID), quote the spec,
   reference the source location, and explain the regression/mismatch.
4. **Fix and verify:** implement the change, compile, refactor/move/add tests as appropriate, run all
   tests and fix failures, move on.
5. Track how many issues were found and resolved.
6. Complete all stable artifacts, including `.spec/protocol.txt` and every
   `conformance/<SPEC>-matrix.md`, before the final fingerprint and cache identity. Create or
   complete missing conformance evidence without discarding existing entries. Then use the
   workflow's frozen-revision parallel verification contract for the final complete build/tests
   or exact validation-cache hit and independent review.

## Output
Updated source, tests, and docs, with the persistent conformance index and exhaustive per-spec
matrices complete and maintained. Missing artifacts cannot pass verification. When done (or if no
issues are found), announce completion and proceed to Connector Metadata Authoring.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- This is the final static conformance gate before security and runtime validation: be thorough.
   Check **every** requirement, not only refactored areas.
- If no issues are found, say so clearly and announce implementation completion.
