---
name: aio-connector-core-implementation
description: "Implement a real SDK-backed release vertical slice, then complete selected capabilities and unit tests from specs and invariants. Use in the AKRI-CONNECTOR-BUILDER pipeline after scaffolding."
---
# Core Implementation

## Persona
A **Seasoned Software Engineer** who writes clean, well-tested code strictly from specifications — no
invented behavior, connected release behavior first, and untested code is unfinished code.

## Objective
Implement the core business logic for all modules, making the scaffolding functional. Produce fully
working, tested, documented code that faithfully implements the specifications.

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, plus
`{connector-name}/invariants.md`, `{connector-name}/examples.md`, any coding-standards file, and the
frozen intake's implementation approach, selected dependency/version when applicable, and optional
capability selection.

## Approach
**Step 1 — Establish the SDK-backed vertical slice first.** Preserve accepted scaffolding, including
an older deficient scaffold during failed-Core resume: repair its real executable composition in
place, never rerun `create-connector`. Start with the actual Rust release binary/active SDK features
or .NET published executable/SDK hosted services. Feed standard AIO configuration through the SDK's
real lifecycle and dispatch into one specification-backed selected protocol operation. For a selected
data source, deliver the result/event through its approved SDK destination and assert independent
receipt/readback; do not discard polled data or events. For selected management actions, exercise
the real action handler/result and cancellation without inventing telemetry. For discovery-only
or empty/no-data-plane selections, prove the mandatory SDK configuration/lifecycle, health,
observability, Schema Registry and cancellation path without fabricating a source or destination.
Implement real establishment/failure/recovery health and injected OTLP on this slice, not
configuration-only readiness. Add production-path regression tests before expanding disconnected utilities.
Implement the agents' ADR-sourced configuration baseline through the template SDK handlers:
Rust endpoint `specification()`, data-operation `definition()`, and management-action definitions;
.NET's equivalent ADR client path. Trace endpoint address/type, additional configuration,
dataset/data-point/event/stream configuration, data sources, destinations, and action
configuration/target URI to ADR fields. Parse their CR JSON strings into resource-scoped state;
handle SDK updates/deletes and invalid-resource configuration status/health without process exit.
Never load device/asset configuration from an invented file or environment-variable mount list.
Only AIO-defined configuration-mount files and metadata-declared template connector-level settings
are permitted; missing optional files degrade gracefully and do not supply ADR field defaults.

Add tests using SDK/ADR-shaped definitions and the exact configuration JSON strings that CRs carry,
not temporary connector configuration files. Cover two assets with equal dataset names, independent
endpoint settings, update/delete notifications, and invalid JSON on one resource without killing
another. Add a startup regression through the real release initialization with only AIO mounts
and zero devices; prove it reaches the SDK run loop with optional files absent. Do not bypass
production initialization with a test-only loader, disabled SDK feature, or alternate entrypoint.
Record source/ADR field mappings and passing test names for `adr-sourced-configuration`.

Then order the remaining modules by dependencies and complete every frozen selected capability.
Present the explicit numbered list with a reason
for each position as status information, then immediately begin the vertical slice. **Do not ask the
user to confirm or approve the implementation order.**

**Step 2 — Implement module by module.** For each module, before moving on:
1. Scope context to the current module; expand only as dependencies require.
2. Implement strictly from specifications and invariants — no invented behavior; add new
   abstractions/dependencies only when there is a significant advantage, and sparingly.
3. Compile/test the actual release selection; fix errors and reasonable warnings until clean. For
   C#/.NET use host-native `dotnet build`/`dotnet test`. For Rust use only the bundled
   `scripts/Invoke-AkriRustContainerValidation.ps1` by absolute plugin path (for example
   `-Commands 'check,test'` while iterating; the default full run of fmt-check, check, clippy
   `-D warnings`, and test for gate evidence). Dead/unused-code warnings
   caused by not-yet-implemented modules are acceptable. If issues persist after five attempts, change
   approach using resolved SDK evidence or report the concrete blocker. Do not restart unchanged API
   probes or move on to disconnected helpers while the SDK-backed slice is still missing.
4. Document all code — functions/methods, macros, classes, structs, records, traits/interfaces, enums
   (and each variant); all parameters, fields, return values, and errors/exceptions/panics — in the
   language's **native documentation construct**, per the agent's non-negotiable documentation
   baseline. Comments must **clearly and concisely state intent**, and docs must be updated to match
   the real behavior now that bodies are implemented (not left as scaffolding placeholders).
5. Generate unit tests from specifications and invariants only — happy path, edge cases, invalid
   input, and property tests where invariants allow. Every assertion must map to a spec or invariant.
   Document test support code too.
   Configuration booleans, unconditional true results, unused helpers and payload-only assertions
   cannot satisfy production contracts; exercise the actual release dispatch and external effect.
6. Run the test suite; fix the code until all pass.

**Step 3 — Create conformance evidence after initial implementation.** Once the modules contain
working code, create `{connector-name}/.spec/protocol.txt` as the persistent index and
`{connector-name}/conformance/<SPEC>-matrix.md` for each specification. Enumerate every normative
MUST/SHALL/SHALL NOT/MUST NOT/REQUIRED requirement with spec section and line. Classify scope against
the approved roles and selected capabilities without omitting out-of-scope requirements; record
the rationale for exclusions and intentional deviations. Record `met`, `gap`, or
`intentional-deviation`, implementation `file:line`, tests, and passing-run evidence. Every `met`
row requires a passing test. Fix gaps with code, spec-citing comments, and regression tests; never
fabricate coverage. Maintain existing entries on subsequent runs instead of regenerating them.
Cross-Check audits and maintains these artifacts, but initial creation belongs to this step.

**Step 4 — Verify the complete stable revision.** Finish the index, all per-spec matrices, source,
tests, and other stable artifacts before deriving the final validation-cache identity and running
the final complete build/tests. Missing or incomplete conformance artifacts prevent a passing
receipt even when code compiles and earlier tests passed.
Obtain the configured independent full review, fix findings with focused regression tests, and
rerun the complete build/tests before acceptance. Preserve original test outputs and review findings
in the session state. Use the launcher's failure receipt contract for a remaining blocker.

## Output
Fully implemented, documented source and unit tests in the inner
`{connector-name}/{connector-name}/` project; clean compilation;
all tests passing; the persistent `.spec/protocol.txt` index and exhaustive per-spec
`conformance/<SPEC>-matrix.md` files with scope, implementation, and passing-test evidence.

## Rules
- Follow any coding-standards file. Implement strictly from specifications — do not invent requirements.
- **Leverage the Azure IoT Operations SDKs** (and other well-maintained libraries) instead of
  hand-rolling what they already provide. Aim for **high quality, production-grade** code and, where
  the protocol and SDK allow, **fault tolerance**: retries with backoff, clean reconnect/recovery,
  timeouts, fail-safe behavior, and no data loss or corruption on error. Do not fake fault-tolerance
  the spec or SDK cannot support — flag it as an assumption or future intent instead.
- For `existing-library`, exercise the exact approved southbound dependency's real API in code and
  tests; never silently substitute it or implement a parallel stack. For `from-scratch`, implement
  the protocol from cited specifications without adding a competing protocol dependency. Neither
  choice replaces mandatory AIO SDK integrations.
- Implement exactly `SelectedCapabilities`. Polling and MQTT telemetry are independently optional;
  other selected features imply neither. Omit unselected production behavior, configuration,
  examples, and tests. An empty selection still requires the mandatory lifecycle, resilience,
  observability, health, and cancellation behavior.
- Every test assertion traces to a specification or invariant; no module ships without comprehensive tests.
- If a spec is ambiguous or a gap surfaces during implementation, ask the user before proceeding.
- Compile and test after each module — never batch. Fix the implementation, not the spec, unless the
  spec is clearly wrong. On "stop", save `AIO-CONNECTOR-SESSION-STATE.md` with the current module and open issues.
- For Rust, keep the inner `Cargo.toml` `rust-version` equal to the `Dockerfile.release`
  `RUST_VERSION` major.minor. After any dependency change, rerun the container script alone with
  `-Commands 'lock'` so `Cargo.lock` stays MSRV-compatible. The orchestrator checks the
  `rust-toolchain-pinned` gate. Host Rust/Cargo is optional and never gate evidence.
