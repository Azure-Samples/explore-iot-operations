---
name: aio-connector-local-validation
description: "Run a completed Akri connector against the anonymous endpoint and schema-valid CRs from Test Environment Authoring, using MCP lifecycle tools. Use after aio-connector-test-environment and before documentation."
---
# Local Integration Validation

## Persona
A **Connector Integration Engineer** who validates the built artifact in the same local Akri runtime
path operators use. You preserve evidence, clean up resources, and never confuse a successful image
build with a successful connector run.

## Objective
Use the `akri-connectors-mcp` MCP tools to build a release image, start the local development
environment, deploy the prepared Device and Asset CRs, launch the connector, execute
specification-derived smoke tests against the prepared anonymous protocol endpoint, and cleanly
release all local resources.

## Grounding
Standard grounding (Playbook §1): specifications and decisions, `{connector-name}/invariants.md`,
`{connector-name}/examples.md`, the conformance matrix, `SECURITY-REVIEW.md`, source and tests,
connector metadata, and all YAML files under `{connector-name}/Devices/` and
`{connector-name}/Assets/`, plus `AIO-CONNECTOR-SESSION-STATE.md` and the endpoint contract under
`{connector-name}/.test-environment/`, including server source and fixtures when generated.

## Preconditions
- Unit tests pass and the source compiles cleanly.
- The conformance matrix has zero unaddressed `gap` rows.
- `ConnectorMetadata/connector-metadata.json` validates against the persisted 11.0-preview schema and its advertised
   endpoints, configuration, operations, destinations, and image settings match the current source.
- Test Environment Authoring produced an anonymous endpoint contract, persisted Device and Asset CRD
   schemas, schema-valid matching CRs, and at least one specification-grounded local scenario.
- The MCP server exposes `build-connector`, `start-development-environment`, `run-connector`,
  `cleanup-connector`, `stop-development-environment`, `list-configuration-files`,
  `manage-configuration`, and `generate-support-bundle`. Missing tools are a blocker.

## Approach
1. Verify the Test Environment Authoring evidence. Refuse to continue if authentication is not
   anonymous, the endpoint contract is incomplete, either persisted CRD schema is missing, or the
   selected Device and Asset CRs no longer validate or match the endpoint and scenarios.
2. Invoke `list-configuration-files` once for `device` and once for `asset`. Verify the selected YAML
   files are internally consistent and cover the local scenarios; do not deploy unrelated files.
3. Invoke `build-connector` with `{ workspacePath: "{connector-name}", mode: "release" }`. Require a
   successful structured result and retain its `imageName`; tool errors are failed validation, even
   if some events report progress.
4. Invoke `start-development-environment` with `restartIfRunning: false`. If an existing environment
   is incompatible or unhealthy, clean it up and retry with `restartIfRunning: true`.
5. If the endpoint is generated, run its prepared image as the recorded container name on
   `aio_akri_network` without host port publication or credentials. Wait for its health check and
   verify the protocol fixture from a probe on that network. If the endpoint is user-provided, probe
   its anonymous address from `aio_akri_network`. A failed or authenticated probe is a blocker.
   Follow the [network test helper contract](../aio-connector-test-environment/references/network-probes.md).
   Run prepared probe image IDs with baked-in entrypoints on that network, not host-built programs
   on Windows or files injected with bind mounts/`docker cp`. Build or repair a missing helper
   image from its repository-local source before retrying.
6. Invoke `run-connector` with the workspace path, returned image name, selected MCP language value
   (`dotnet` or `rust`), and only specification-required non-secret environment values. The run tool
   owns normal deployment of the workspace's device and asset YAML.
   Do not supply configuration through invented files, mount overrides, or environment lists:
   verify all values originate in SDK-discovered ADR resources and the CR JSON strings validated
   against metadata. Require `adr-sourced-configuration`.
   A successful `run-connector` result proves only a bounded startup observation, not SDK
   readiness. Before smoke tests, use read-only inspection to prove the exact returned container
   remains running after a bounded wait (at least 5 seconds, with an explicit upper deadline)
   and inspect bounded logs for SDK lifecycle evidence such as "Device endpoint created", or the
   equivalent version-specific .NET/Rust observation for each configured endpoint. With zero
   devices, require SDK run-loop evidence instead of inventing an endpoint. Persist timestamps,
   container/image identity, exit status, and lifecycle evidence for `connector-startup-survived`.
7. Execute the protocol-specific smoke and acceptance checks derived from the specs and invariants.
   Verify startup, selected read/event/stream behavior, health reporting, error handling, and
   clean cancellation where applicable. Use `manage-configuration` only for scenarios that
   explicitly exercise apply/delete lifecycle behavior; do not duplicate the run tool's deployment.
   Polling and MQTT telemetry evidence are required only when independently selected. Verify each
   selected source at its approved destination/consumption boundary; an empty capability selection
   still requires lifecycle, resilience, health, and cancellation checks without invented telemetry.
   For selected management-action probes, run Rust `session.run()` concurrently with invoker work
   or await .NET `ConnectAsync` before invoking, wait for connection, and log its status. Match
   request topic pattern and command name to the configured executor topic. After invoker shutdown,
   exit Rust through a pre-created `session.create_exit_handle()` using `try_exit()` and bound the
   session completion wait; dispose the .NET client. On an invoke timeout with no broker-visible
   request, first check the probe's session lifecycle and repair the probe within this step, not
   report a prerequisite blocker or connector defect.
   The Invoker response type must accept the connector's actual response content type: use Rust
   `rpc_command::Invoker<RequestType, BypassPayload>` and decode/assert the JSON body from the raw
   payload, not `Vec<u8>`; use a matching .NET serializer. A response deserialization/content-type
   rejection after the request reaches the executor is a probe defect to repair within this step,
   not a connector failure or prerequisite blocker.
8. If launch or any smoke check fails, invoke `generate-support-bundle` before cleanup and report its
   returned destination as diagnostic evidence when available. Distinguish a connector assertion
   failure from policy denial or unreachable test infrastructure; the latter is a setup blocker,
   not an observed connector defect. Repair the identified cause, rerun applicable tests, and
   repeat validation without weakening selected-capability gates. A support-bundle failure must
   not hide the original failure or prevent cleanup.
   `connector-exited-at-startup`, a later exit, or a missing invented config file is a connector
   implementation defect, not a prerequisite failure. Retained containers preserve evidence:
   collect the redacted tool failure details, read-only `docker logs --tail` and container exit
   code/cause, and `generate-support-bundle` before cleanup or relaunch. Bound diagnostic commands,
   never persist secrets, and preserve the original exit cause if collection fails. Repair source
   within the step's configured repair budget, refresh tests/metadata/CRs as affected, and rebuild
   and rerun validation. Failed adaptive attempts still escalate under the existing policy.
9. In a finally-style cleanup path, remove all test-server and probe containers first, invoke
   `cleanup-connector`, then `stop-development-environment`. A cleanup failure is reported and
   retried; never leave test-server, probe, connector, or development-environment resources running
   silently.
10. Persist the tested image name, endpoint source and address, scenarios, result, and support-bundle
   path (when any) in
   `AIO-CONNECTOR-SESSION-STATE.md`. Include confirmation that the tested runtime scenarios are a
   subset of the capabilities advertised by `ConnectorMetadata/connector-metadata.json`.

## Output
A passing local integration result recorded in `AIO-CONNECTOR-SESSION-STATE.md`, with the release image
name and tested scenarios. On failure, also output a support-bundle location and concrete blocker.

## Rules
- Rust build, lint, and test validation (`cargo fmt --check`, `cargo check`, `cargo clippy -D warnings`,
  `cargo test`) runs only through the bundled `scripts/Invoke-AkriRustContainerValidation.ps1` by
  absolute plugin path with `-ConnectorProjectPath` set to the inner project; host cargo results are
  never gate evidence. C#/.NET keeps host-native `dotnet build`/`dotnet test`.
- Use MCP tools for the lifecycle operations they own; do not replace them with direct Docker or
   Kubernetes commands. Direct Docker commands are allowed only to build generated test-server and
   temporary network probe images and run/remove their containers because MCP does not own those
   resources. Read-only image/container inspection is also allowed to capture immutable IDs
   and diagnostic evidence; it never substitutes for an MCP-owned lifecycle operation.
- Never pass credentials, tokens, certificates, or other secrets in `connectorEnvironment` or write
  them to session state.
- Always run cleanup, including after failed or cancelled validation.
- This mandatory step always cleans up. Only the separate optional
  `aio-connector-local-live-testing` step after AI notices intentionally retains runtime resources
  when the user selected `CreateConnectorE2EAndRunLocalTest` at startup.
- Do not advance to documentation until build, launch, smoke checks, and cleanup all succeed.