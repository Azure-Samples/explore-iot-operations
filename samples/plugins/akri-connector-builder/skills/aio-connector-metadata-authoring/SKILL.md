---
name: aio-connector-metadata-authoring
description: "Derive, write, and validate connector-metadata.json against the AIO 11.0-preview schema after final code conformance. Use before security and local integration validation in the AKRI-CONNECTOR-BUILDER pipeline."
---
# Connector Metadata Authoring

## Persona
A **Connector Packaging Engineer** who turns verified implementation behavior into an exact,
machine-validated distribution contract. You describe only capabilities the connector implements and
never use metadata to promise future behavior.

## Objective
Derive `{connector-name}/ConnectorMetadata/connector-metadata.json` from the finished source, tests, configuration,
protocol conformance matrix, build files, and approved release inputs. Validate it against the
authoritative Azure IoT Operations Connector Metadata 11.0-preview JSON Schema.

## Authoritative references
- Schema: `https://json.schemastore.org/aio-connector-metadata-11.0-preview.json`
- Official packaging guidance and examples:
  `https://github.com/Azure/iot-operations-sdks/tree/main/doc/akri_connector`
- Local structural example: `examples/minimal-dataset-connector-metadata.json`

The schema is authoritative if an example differs from it. Examples illustrate shape only; never
copy their connector names, endpoints, limits, destinations, versions, or defaults into an output.

## Grounding
Standard grounding (Playbook §1): all specifications and decisions, source and tests, dependency and
container build files, device/asset examples, `invariants.md`, protocol conformance matrix, release
identifiers, the frozen intake manifest, and every connector-specific configuration schema or key.

## Approach
1. Retrieve the versioned 11.0-preview schema and verify its `$id` exactly matches the authoritative
  schema URL. Persist the verified document at
  `{connector-name}/.spec/aio-connector-metadata-11.0-preview.schema.json` for repeatable validation.
  A fetch failure or identity mismatch is a blocker.
2. Build an evidence map before writing JSON:
   - Derive `name`, semantic `version`, image repository/tag, preview state, and supported
     architectures from approved release inputs and actual container build targets.
   - Derive language, language version, and exact AIO SDK package versions from manifests and lock
     files.
   - Derive connector configuration keys, secret aliases, and storage mounts from code paths that
     consume them. Never include secret values.
   - Derive each inbound endpoint type, protocol version, authentication type, address requirement,
     additional configuration schema, and default enablement from implemented parsing and tests.
     The agents' ADR-sourced configuration baseline is mandatory: derive
     `additionalConfiguration`, dataset, data-point, event, stream, and management-action
     configuration schemas from the code parsing the corresponding SDK/ADR fields, not from
     an invented connector JSON file. Match types, required fields, bounds, defaults, unknown-field
     handling, and `actionConfiguration` / `targetUri` semantics to the actual parser.
     Metadata-declared template connector-level additional settings are separate and never
     substitute for resource-level ADR fields.
   - Include datasets, event groups/events, streams, management groups/actions, limits, field
     requirements, action types, and destinations only when implemented and tested. Defaults must
     match runtime behavior.
     They must also match `SelectedCapabilities`: omit unselected optional behavior even if a
     template or incidental source supports it. Polling and MQTT telemetry are independently
     selected; AIO control/health MQTT traffic does not enable the optional telemetry destination.
   - Derive readiness probe commands from the release image and implemented health behavior. Omit a
     probe if no image command can truthfully implement it.
   - Set allocation and replica recommendations from the implemented topology. Do not advertise
     cross-replica coordination unless the implementation and deployment contract prove it.
3. Read non-derivable human metadata from the frozen intake manifest: portal description, semantic
  version, preview status, maintainer/vendor values or explicit omission, approved image name and
  tag/digest, and any architecture requirements. Do not ask the user for these values during this
  skill. If a required value is absent or conflicts with implementation evidence, stop with an
  intake-contract error so the coordinator can correct intake; optional fields marked omitted stay
  omitted.
4. Write `{connector-name}/ConnectorMetadata/connector-metadata.json` with `$schema` set to the
  authoritative 11.0 URL.
   Use only schema-defined properties and keep nested configuration schemas valid Draft-07 schemas.
5. Validate the artifact with a standards-compliant JSON Schema Draft-07 validator against the
   persisted schema. Resolve every validation error and rerun until there are zero errors.
6. Perform semantic cross-checks the schema cannot prove: every advertised capability has a code
   location and passing test; every required runtime input is represented; image tag equals the
   approved semantic release version; destination defaults are supported; and no unimplemented
   capability is advertised.
   Validate decoded CR configuration JSON strings and positive/negative ADR-shaped parser fixtures
   against each matching metadata schema. Reject a CRD-only check that leaves embedded JSON
   unchecked. Every required runtime value must have an ADR field-to-parser-to-schema mapping;
   attest `adr-sourced-configuration` with those mappings and passing evidence.
7. Add a metadata evidence section to `AIO-CONNECTOR-SESSION-STATE.md` recording the schema `$id`,
   validation command/result, and source/test evidence for each advertised endpoint capability.

## Output
- `{connector-name}/ConnectorMetadata/connector-metadata.json`
- `{connector-name}/.spec/aio-connector-metadata-11.0-preview.schema.json`
- Metadata validation and evidence in `{connector-name}/AIO-CONNECTOR-SESSION-STATE.md`

## Rules
- The generated artifact, not the local example, is the publication input.
- Do not hand-wave schema validation or treat editor diagnostics as sufficient. Run a Draft-07
  validator and require zero errors.
- Do not invent limits, authentication types, configuration keys, defaults, or supported operations.
- Never include credentials or secret values; metadata contains aliases and descriptions only.
- Do not reopen intake or ask metadata questions in worker mode. Use the confirmed intake values,
  derive implementation facts from evidence, and fail explicitly if those sources are insufficient.
- Any later source, dependency, configuration, image, endpoint, or release-version change invalidates
  metadata evidence. Rerun this skill before local validation and optional live testing.