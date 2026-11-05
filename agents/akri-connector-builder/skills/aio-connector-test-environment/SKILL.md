---
name: aio-connector-test-environment
description: "Prepare an anonymous protocol test endpoint and matching schema-valid Device and Asset CRs for local connector testing. Use after security review and before Local Integration Validation in the AKRI-CONNECTOR-BUILDER pipeline."
---
# Test Environment Authoring

## Persona
A **Protocol Test Engineer** who turns specification examples into the smallest deterministic
endpoint and configuration needed to exercise real connector behavior.

## Objective
Prepare either a user-provided anonymous test endpoint or a generated minimal protocol server, plus
matching Device and Asset custom resources (CRs). Prefer a generated server packaged as a Docker
container that Local Integration Validation can run with the development-environment and connector
containers on the `aio_akri_network` Docker network.

## Grounding
Standard grounding (Playbook §1): the selected protocol and role, approved behavior and scenarios,
the protocol specification, `{connector-name}/invariants.md`, `{connector-name}/examples.md`, source
and tests, connector metadata, and the bundled Azure IoT Operations Device and Asset CRD schemas at
`references/device-crd-schema.json` and `references/asset-crd-schema.json`.

Use the Azure IoT Operations SDK
[Polling REST Thermostat Kubernetes resources](https://github.com/Azure/iot-operations-sdks/tree/main/dotnet/samples/Connectors/PollingRestThermostatConnector/KubernetesResources)
as a non-normative structural example for Device endpoint and Asset dataset relationships. The
selected protocol, connector implementation, and bundled CRD schemas remain authoritative. Do not
copy the sample's authenticated endpoint configuration.

## Preconditions
- Security Review is complete and unit tests pass.
- The user has selected a user-provided test endpoint or a generated endpoint during input
  gathering. Any unresolved protocol behavior or fixture values have been gathered one at a time.
- The endpoint can operate without authentication. The current local dev-kit transport does not
  support delivering authentication material to the connector, so authenticated endpoints are not
  supported by this workflow.

## Approach

1. Establish the endpoint source selected during input gathering:
   - For a user-provided endpoint, tell the user that local validation supports anonymous access
     only. Record its protocol, version, address, expected behavior, and non-secret fixture data. Do
     not accept credentials, tokens, certificates, secret references, or an endpoint that requires
     authentication.
   - Otherwise, derive a minimal deterministic server contract from the approved protocol role,
     `GeneratedTestAsset`, operations, edge cases, and acceptance scenarios. Do not ask the user to
     choose an asset deferred from intake. Ask only about a genuinely new unresolved ambiguity.
     For selected polling, provide at least five independently addressable, deterministically
     changing points, or all feasible points with the protocol limitation documented. Selected
     Events and Streams each require a distinct simulated source. Selected Management Actions
     require a safe reversible operation with observable effect and cancellation; derive it from
     evidence and ask only when materially different or unsafe choices remain. Omit all sources
     for unselected capabilities.
2. Create `{connector-name}/.test-environment/README.md` with the endpoint source, protocol, version,
   address, health probe, fixtures, and scenario contract. For a generated endpoint, also create a
   Dockerfile, server source, deterministic fixtures, and a container health check in that directory.
   Use a maintained protocol library instead of hand-rolling protocol parsing. Pin dependencies and
   the base image to immutable versions. Expose only the protocol port to `aio_akri_network`; do not
   publish it to a host port or implement authentication.
   For either endpoint source, prepare any scenario-specific network helpers needed to exercise
   selected capabilities, especially SDK-backed management actions. Follow the
   [network test helper contract](references/network-probes.md): package custom helpers as
   self-contained Linux images under `.test-environment/probes/{purpose}/`, with no host-file
   injection. Record their entrypoints, non-secret configuration, bounded assertions, and cleanup.
3. Assign a stable DNS-safe test-server container name and use that name in the Device inbound
   endpoint address, with the protocol scheme and container port. For a user-provided endpoint, use
   the exact approved anonymous address. Set `authentication.method: Anonymous` explicitly.
4. Start with the bundled Device and Asset CRD schemas. If the user's target AIO version requires
  newer schemas and the user provides or approves an authoritative official source, use those
  instead. Persist the exact schemas used under `{connector-name}/.spec/device-crd-schema.json` and
  `{connector-name}/.spec/asset-crd-schema.json`. Record whether each schema came from the bundled
  baseline or an approved newer source in `{connector-name}/.test-environment/README.md`; never
  depend on schemas outside the generated connector workspace.
5. Create at least one Device CR under `{connector-name}/Devices/` and one Asset CR under
   `{connector-name}/Assets/`. The Device defines the anonymous inbound protocol endpoint. Each Asset
  references that Device and endpoint and includes the selected datasets, selected events and
  streams, selected management actions, data sources, configurations, and selected destinations
  needed to exercise every approved local acceptance scenario. Omit unselected optional
  capabilities. Use
   `apiVersion: namespaces.deviceregistry.microsoft.com/v1` and the required namespace.
   Apply the agents' ADR-sourced configuration baseline: CRs carry every device/asset/operation
   value the connector needs, including endpoint address/type, `additionalConfiguration`,
   `datasetConfiguration`, each point's `dataSource` / `dataPointConfiguration`,
   `eventConfiguration`, stream configuration/destinations, and management-action
   `actionConfiguration` / `targetUri` when selected. Encode configuration as the CRD-required
   JSON strings, not invented connector configuration files or environment-variable lists.
   No configuration-mount side channel may compensate for a missing CR value.
6. Parse every YAML file with a structured YAML parser and validate it against its persisted Draft-07
   CRD schema. Also verify cross-resource semantics: unique names, valid Device/endpoint references,
   anonymous authentication, endpoint protocol/version agreement, fixture-backed data sources,
   connector-metadata capability agreement, and no embedded secret values.
   Decode every embedded configuration JSON string and validate it against the corresponding
   schema in `ConnectorMetadata/connector-metadata.json`. Reject malformed JSON or parser/schema
   drift even when the outer CRD accepts a string. Exercise those exact ADR-shaped definitions
   in connector tests; record field/parser/schema/scenario mappings for `adr-sourced-configuration`.
7. Build any generated test-server and probe images and run their unit or contract tests without
   starting the shared development environment. Record their immutable image IDs. Direct Docker
   builds are allowed for these test images, not production connector images. Do not leave a test
   container running; Local Integration Validation owns the networked run.
8. Persist the endpoint source, image and container names when generated, address, health check,
   fixture contract, CRD schema sources, validation commands/results, and scenario-to-CR mapping in
   `AIO-CONNECTOR-SESSION-STATE.md`.

## Output
An anonymous endpoint contract at `{connector-name}/.test-environment/README.md`; for generated
endpoints, a buildable server in that directory; persisted Device and Asset CRD schemas; schema-valid
matching CRs under `{connector-name}/Devices/` and `{connector-name}/Assets/`; and session-state
evidence for Local Integration Validation.

## Rules
- Anonymous authentication is mandatory for this local workflow until the dev-kit supports
  authentication transport to the connector. Never collect, generate, or embed credentials.
- Keep generated servers minimal, protocol-correct, deterministic, and limited to approved test
  scenarios. They are test infrastructure, not production server implementations.
- Prefer a Dockerized server on `aio_akri_network`. Do not use host networking or expose a host port
  unless the protocol cannot work on a Docker bridge and the user explicitly approves the exception.
- Device and Asset YAML must validate against the exact persisted CRD schemas before this skill
  completes. Do not defer CRD creation or schema validation to Local Integration Validation.
- Treat bundled schemas as immutable reference assets during connector generation. Copy them into
  the connector's `.spec/` directory; do not edit the bundled originals.
- Do not start, stop, or modify MCP-owned development-environment or connector resources in this
  skill.