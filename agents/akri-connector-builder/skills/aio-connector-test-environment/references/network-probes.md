# Network test helpers

Use this contract for temporary probes needed by Test Environment Authoring, Local Integration
Validation, and Local Live Container Testing. These are generated test infrastructure, not production
connector code, a new MCP tool, or a replacement for MCP-owned lifecycle operations.

## Prepare a self-contained Linux image

- Reuse a suitable approved local client image when it can perform the required check. Otherwise
  create the smallest scenario-specific helper under
  `{connector-name}/.test-environment/probes/{purpose}/`, with source, a Dockerfile, and a narrow
  build context. Add a `.dockerignore` excluding `bin`, `obj`, `target`, and other host build
  outputs. Build inside the image for Linux; do not inject Windows-built binaries.
- Use the approved SDK and protocol dependencies, pinned toolchains and base images, and the same
  anonymous endpoint contract as the test server. Keep dependencies available through approved
  sources; image builds do not authorize new network destinations.
- Keep the entrypoint, container paths, and non-secret endpoint configuration in the image.
  Derive actual SDK configuration keys from the implementation, not invented connector environment
  variables. Use `aio-broker` and port `1883` for the local broker and the recorded test-server DNS
  name for a generated endpoint.
- Direct `docker build` is permitted for these probe images and generated test-server images only.
  Production connector image builds still require MCP `build-connector`. Do not push helper images.
  Record the build context, source revision, image name, and resolved immutable image ID in the
  endpoint contract before networked validation.

Run the following command shapes from the helper's repository-local build context, substituting
the recorded connector name and purpose:

```text
docker build --tag {connector-name}-{purpose}-probe:local .
docker image inspect --format '{{.Id}}' {connector-name}-{purpose}-probe:local
docker run --rm --name {connector-name}-{purpose}-probe --network aio_akri_network {image-id}
```

The final argument is the actual immutable image ID returned by inspection, not the literal
placeholder. Use the container's baked-in entrypoint. Do not mount or copy host-built files with
`--volume`, `--mount`, or `docker cp`, use host networking, publish broker ports, or run an
internal-broker check directly on the host. Docker-network DNS names are not host DNS names.

## Execute the selected scenario

- Start the shared AIO environment through MCP before running networked checks. Require the
  prepared endpoint to be healthy/reachable from `aio_akri_network`; compilation alone is not
  connectivity evidence.
- Give each helper a recorded connector-scoped container name. Inspect and reuse or remove only
  resources known to belong to this validation attempt; do not remove another workflow's container.
- Bound SDK connection, request/response, and observation waits, and the host command duration.
  A helper must exit nonzero on timeout, rejected/unmatched responses, failed assertions, or
  incomplete observations. Capture the actual command exit status and non-secret output.
- For selected management actions, use the Azure IoT Operations SDK to send the request through
  MQTT, correlate the connector response, observe the protocol-side state effect, and restore the
  safe reversible fixture state in a finally-style path. Exercise the approved cancellation
  scenario. Calling the simulated device directly is not evidence for the MQTT-to-connector
  management-action path. Keep these SDK-native probes under
  `{connector-name}/.test-environment/probes/management-actions/`. Follow the selected SDK's
  session lifecycle, not just its invoker API:
  - Rust: a probe that constructs `Session::new` must also invoke `session.run()`. Inspect the
    probe source before running it. Spawn or join `session.run()` concurrently with the invoker
    work and wait for connection before invoking; constructing a managed client alone does not
    establish MQTT connectivity. Create the exit handle before running the session
    (`session.create_exit_handle()`); after the invoker shuts down, call `try_exit()` on that
    handle and await session completion with a bounded shutdown wait, including on failure.
  - .NET: connect the session client (for example, `ConnectAsync`) and await connection before
    invoking; dispose the client afterwards, including on failure.
  Match the probe's request topic pattern and command name to the connector's configured executor
  topic. The Invoker response type must accept the connector's actual response content type.
  For Rust, declare `rpc_command::Invoker<RequestType, BypassPayload>`, using
  `azure_iot_operations_protocol::common::payload_serialize::BypassPayload`, then decode and
  assert the JSON response body from the raw payload. Do not use `Vec<u8>` as the response type:
  it rejects `application/json` responses. For .NET, use a serializer matching the connector's
  declared response content type. A response deserialization/content-type rejection after the
  request reaches the executor is a probe defect to repair within the step, not a connector
  failure or prerequisite blocker. Rebuild the repaired probe image and rerun the scenario;
  decoding raw payloads does not replace response-body assertions.
  Log whether the MQTT connection was established and retain broker-visible request
  evidence. An invoke timeout with no broker-visible request is a probe/setup defect, not a
  connector defect or prerequisite blocker. First check the probe's session lifecycle and topic
  mapping, repair the probe within the step, rebuild its image, and rerun the selected scenario.
- Keep the long-running MQTT observer read-only. Use a separate bounded helper for management
  requests or other tests that mutate fixture state. Do not add tests for unselected capabilities.
- Remove temporary helper containers on success, failure, cancellation, or host timeout, including
  when the optional live demonstration retains its AIO, connector, endpoint, and observer containers.
  `--rm` handles normal exit; verify removal and explicitly clean up an owned container left running
  after interruption. Mandatory Local Integration Validation still performs its complete cleanup.

## Report blockers accurately

A denied command or unreachable broker is a test-setup blocker, not proof of a connector defect.
Retain the actual non-secret denial code/reason or connection error and an evidence pointer; do not
infer a blanket Docker/network prohibition from one rejected command. If the documented image-based
path is denied, stop and report that specific blocker. Never bypass hooks, broaden permissions,
obfuscate rejected commands, silently deselect a capability, or mark unexecuted checks passed.
