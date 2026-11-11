---
name: aio-connector-scaffolding
description: "Create an Akri connector workspace with the MCP create-connector tool, then generate compilable source scaffolding from protocol specifications and confirmed intake requirements. Use as the first step of the AKRI-CONNECTOR-BUILDER pipeline."
---
# Source Code Scaffolding

## Persona
A **Seasoned Software Engineer** who thinks in types, contracts, and module boundaries before
implementation — incorrect scaffolding propagates everywhere, so you get the foundation right.

## Objective
Create the canonical Akri connector workspace through the `akri-connectors-mcp` MCP server, then
generate complete compilable scaffolding in the chosen language: all types/enums/structs/constants,
all error types, correct module declarations and imports, all function/method signatures, stubbed
trait/interface implementations, a public API surface derived from protocol specifications and
confirmed intake requirements, full documentation comments on every item, and language-appropriate
"not implemented" markers in place of
business logic (`todo!()` Rust or `throw new NotImplementedException()` C#).

## Grounding
Standard grounding (Playbook §1): the protocol specifications, confirmed intake requirements and
decisions, optional user-provided supporting documents, and any coding-standards file. Derive module
structure, types, signatures, and component boundaries from that evidence and the selected SDK's
contracts. The frozen intake supplies `ProtocolImplementationApproach`, the exact southbound
dependency/version when selected, and independently selected optional capabilities.

## Approach
Preserve the SDK's actual executable composition and standard deployment configuration. Do not replace it with unused imports,
optional-disabled SDK dependencies, bespoke JSON loaders, or loopback MQTT defaults. Rust release
features and .NET published/hosted wiring must activate mandatory AIO integration. From-scratch
approval is only for the southbound protocol. Stub bodies are allowed here, not at Core acceptance.
Inventory scaffold-owned sampling/action mocks, unconditional ready/healthy defaults, and unsupported
dispatch/destination arms in the session snapshot. Classify each against frozen mandatory/selected
behavior for replacement during Core Implementation; do not mistake the SDK sample for finished
protocol integration or move protocol implementation into MCP scaffolding.
Scaffold the agents' ADR-sourced configuration baseline on top of the `create-connector` template's
actual SDK handlers. Preserve Rust `ConnectorArtifacts::new_from_deployment` / `BaseConnector`
observations and .NET `ConnectorFileMountSettings` / ADR client wiring. Define parsers for SDK
endpoint specifications, data-operation definitions, and management-action definitions, with
resource-reference-keyed state and update/delete handlers. Never scaffold `from_environment()`
as a loader for invented `connector-config.json` / `config.json`, a global startup configuration,
or an environment-variable list that substitutes for SDK mount discovery.
Keep initialization and the zero-device SDK run loop executable; protocol stubs must not run during
empty initialization. Record AIO-only startup and ADR-shaped test requirements in `invariants.md`
for Core Implementation, which owns their implementation and passing regression evidence.
1. **Invoke MCP tool `create-connector` first, before writing any workspace file.** Call it exactly
   once with the selected language, connector name, and the repository's `connectors` parent. For
   .NET, derive `connectorType` from the selected data-operation behavior:
   `EventDrivenTelemetryConnector` for event-driven acquisition or `PollingTelemetryConnector` for
   selected periodic polling. For no polling, use the event-driven template as structure only;
   omit generated polling or event behavior unless selected. Use the returned workspace path as `{connector-name}`. The tool creates the
   workspace root, the `.vscode/` (`launch.json`, `tasks.json`), `Devices/`, `Assets/`, `Output/`,
   and `ConnectorMetadata/` folders, the inner `{connector-name}/{connector-name}/` project, and its
   Dockerfiles. If the tool fails, report its structured result and events, resolve the stated
   prerequisite or input issue, and retry; do not manually recreate files owned by the tool, and do
   not create any workspace file until it succeeds.
2. After reading every registered input through `read-input-document`, create
   `{connector-name}/.spec/grounding-index.json` with `schemaVersion: 1`,
   `classification: "untrusted-derived-evidence"`, `instructionAuthority: "none"`,
   `extractionVersion: 1`, and exactly one source entry per registered document. Each entry contains
   the document's repository-relative `path`, MCP-returned `sha256`, a concise factual `summary`,
   and one or more `evidence` objects with positive `lineStart`, `lineEnd`, and a concise `note`.
   Keep each summary at or below 1,200 characters and each source at or below 20 unique evidence
   entries whose notes are at or below 500 characters. Do not repeat the same line range or
   whitespace-normalized note within a source.
   Submit it to `read-grounding-index` and fix it until the MCP accepts the complete digest-bound
   index. Do not copy full document contents into the index.
3. Plan the module/package layout and component boundaries from the protocol specifications,
   confirmed intake requirements, and selected SDK contracts. For `existing-library`, add the
   exact approved NuGet package or crate under its frozen version policy and use its public protocol
   abstractions. For `from-scratch`, scaffold specification-derived protocol boundaries without a
   competing protocol dependency. Keep the AIO SDK in either approach. Scaffold only selected
   optional capabilities; never infer polling or MQTT telemetry from events or streams.
   This is analysis plus dependency configuration only — write no business logic.
4. Create `{connector-name}/.gitignore` for the chosen language if `create-connector` did not already
   provide a suitable one: use the canonical GitHub `gitignore` template for that language (e.g.,
   `target/` for Rust; `bin/`, `obj/` for .NET/C#) and tell the user exactly what you created.
5. Define all types, enums, error types, and constants in the inner project.
6. Create module files under the inner `{connector-name}/{connector-name}/` project with correct
   signatures, trait/interface stubs, imports, and the public API surface derived from the grounded
   requirements — bodies contain only "not implemented" markers.
7. Create `{connector-name}/invariants.md` (system invariants) and `{connector-name}/examples.md`
   (usage examples), both derived from the specifications.
8. Document every function, method, class, struct, record, trait/interface, enum (and each variant),
   macro, constant, and module in the language's **native documentation construct**
   (rustdoc/XML docs/godoc/docstrings/JSDoc/Doxygen). Each comment must **clearly and concisely state
   intent** (what it is for and why), and **fully document every parameter, field, enum variant,
   return value, and error/exception/panic**. This is the non-negotiable documentation baseline from
   the agent's rules — no construct ships undocumented.
9. Enforce `preserve-MCP-generated-VS-Code-config`: confirm the MCP-generated
   `{connector-name}/.vscode/launch.json` and `tasks.json` are present.
   Preserve both files byte-for-byte throughout this and every later skill: do not edit, rewrite,
   normalize, or replace their values, including changing an absolute bind-mount path to
   `${workspaceFolder}` for portability. If either generated file is invalid, stop and report an MCP
   blocker instead of patching the connector workspace.
10. Compile iteratively until clean; allow only stub-related warnings ("not implemented", dead/unused code).
    For Rust, first set `[package] rust-version` in the inner `Cargo.toml` to the major.minor of
    `ARG RUST_VERSION` in the MCP-generated `Dockerfile.release` (for example `1.88` for `1.88.0`).
    Then resolve `Cargo.lock` with the bundled script by absolute plugin path:
    `scripts/Invoke-AkriRustContainerValidation.ps1 -ConnectorProjectPath <inner project> -Commands 'lock'`.
    Cargo's resolver honors `rust-version` inside the pinned container, so it never selects crates
    that need a newer rustc. Compile with the same script (for example `-Commands 'check'`). Never use
    host cargo as Rust gate evidence. The orchestrator rejects the step unless the
    `rust-toolchain-pinned` gate holds: `rust-version` matches the pin and `Cargo.lock` exists.
## Output
Source scaffolding, build files, and MCP-generated Dockerfiles in the inner
`{connector-name}/{connector-name}/` project; workspace-level `{connector-name}/.gitignore`,
`{connector-name}/invariants.md`, and `{connector-name}/examples.md`; and MCP-generated
`{connector-name}/.vscode/launch.json` and `{connector-name}/.vscode/tasks.json`, plus the
MCP-validated `{connector-name}/.spec/grounding-index.json`. Every artifact is created only after
`create-connector` has established the workspace.

**Does NOT generate:** business logic, protocol unit/contract tests (see
`aio-connector-core-implementation`), config beyond
compilation needs, CI/CD or deployment artifacts, or a README.

## Rules
- Follow any coding-standards file found. Use the language's idiomatic structure and doc format.
- Invoke `create-connector` before creating any workspace file; it owns the workspace root, the
  `.vscode/`, `Devices/`, `Assets/`, `Output/`, and `ConnectorMetadata/` folders, the inner project,
  and the Dockerfiles. Do not replace its generated Docker, configuration, or VS Code files with
  hand-authored alternatives.
- Treat `.vscode/launch.json` and `.vscode/tasks.json` as immutable MCP outputs after creation. Do
   not add tests or review requirements that demand workspace-relative paths or any other rewrite of
   those files.
- Public API surfaces must satisfy the protocol specifications, confirmed intake requirements, and
  selected SDK contracts. Do not invent types/functions/modules beyond what those contracts and
  compilation require.
- Honor the frozen implementation approach. Never replace an approved library or add a competing
  protocol client to a from-scratch implementation without returning to intake for a user decision.
- If a signature in the spec is ambiguous, ask the user. Compile must succeed (stub warnings only)
  before the skill is complete. If the same error survives five attempts, ask for guidance.
