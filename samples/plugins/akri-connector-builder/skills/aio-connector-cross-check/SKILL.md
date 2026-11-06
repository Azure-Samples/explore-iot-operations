---
name: aio-connector-cross-check
description: "Compare implemented source against all specs for mismatches, gaps, and API deviations and fix them. Use in the AKRI-CONNECTOR-BUILDER pipeline after core implementation."
---
# Cross-Check Alignment

## Persona
A **Seasoned Software Engineer** with a code auditor's eye — you treat every deviation from spec as a
potential bug or requirement violation.

## Objective
Compare the implemented source against all specifications to find: **mismatches** (behavior differs
from the spec), **gaps** (a specified requirement with no implementation), **incorrect logic**,
**missing error handling**, **API-surface deviations**, and **naming inconsistencies**. Resolve each
one at a time, most critical first.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, plus
`{connector-name}/invariants.md`, `{connector-name}/examples.md`, the available
`.spec/protocol.txt` index and `conformance/<SPEC>-matrix.md` files, and all source in the inner
`{connector-name}/{connector-name}/` project.

## Approach
Review the complete release wiring, SDK lifecycle and selected capabilities, not only protocol
helpers. Resolve findings supported by the specifications and intake with focused regression tests
and fresh independent re-review. Preserve test results and findings in session state.
Require an explicit ADR provenance review: trace every device/asset/data-operation value from
the SDK endpoint specification, operation definition, or management-action definition through its
ADR field, parser, resource-reference-keyed state, and actual protocol call. Apply the agents'
ADR-sourced configuration baseline to the complete release path. Any non-AIO configuration-mount
file read, invented side-channel input, or global startup configuration is a blocker.
Reject temp-config-file tests as ingestion evidence. Verify AIO-only zero-device startup,
resource-scoped invalid-configuration status/health, independent resource identities, and SDK
updates/deletes before attesting `adr-sourced-configuration`.

1. **Establish complete conformance artifacts:** Core Implementation owns initial creation after
   working code, but this step must create or complete a missing `.spec/protocol.txt` index and
   each `conformance/<SPEC>-matrix.md` before successful verification. This includes resuming older
   sessions with Core Implementation already accepted; do not restart completed phases. Preserve
   existing entries. Enumerate every normative MUST/SHALL/SHALL NOT/MUST NOT/REQUIRED requirement
   with spec section and line, classify scope against approved roles/capabilities, and record
   exclusions or intentional deviations with rationale rather than omitting requirements. Record
   `met` / `gap` / `intentional-deviation`, implementation `file:line`, tests, and passing-run
   evidence; every `met` row requires a passing test.
2. **Compare systematically:** protocol specifications → code (each normative requirement correctly
   implemented?), confirmed intake requirements → code (selected roles, capabilities, and behavior
   fulfilled?), decisions → code (correctly reflected?), and invariants → code (all upheld?).
   Check architectural boundaries, public APIs, and operator-facing behavior against those inputs
   and the selected SDK contracts.
3. **Prioritize** from most critical (incorrect behavior, security gaps, data-loss risk) to least
   (naming, minor doc gaps).
4. **One issue at a time** (Playbook §2): name the affected requirement (with ID), quote the spec,
   reference the exact source location, and explain the mismatch.
5. **Fix and verify:** implement the change, add a specification-citing comment and regression
   test for every fixed gap, compile, run affected tests, update the matrix, tell the user, move on.
6. Track how many issues were found and resolved.
7. Complete all stable artifacts, including the index, every per-spec matrix, and other evidence,
   before the final fingerprint and validation-cache identity. Then use the workflow's
   frozen-revision parallel verification contract for the final complete build/tests or exact
   validation-cache hit and independent review. Missing or incomplete artifacts prohibit a passing
   receipt; a success snapshot or matching fingerprint is not a substitute.

## Output
Updated source, tests, and docs; a complete persistent `.spec/protocol.txt` index and exhaustive
`conformance/<SPEC>-matrix.md` files with scope, implementation, and passing-test evidence. Create
missing conformance artifacts and maintain existing ones in place. On completion, summarize the
changes made.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- If a fix reveals a spec gap (can't be implemented as written), ask the user how to proceed.
- Do not refactor for style or readability here — that is `aio-connector-readability-refactoring`. If no issues
  exist, say so and proceed.
