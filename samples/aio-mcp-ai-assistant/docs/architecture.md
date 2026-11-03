# Architecture and contracts

This document describes the code and manifests in the
[operations assistant sample](../README.md), not a claim about a
currently running deployment.

## Relationship to the other scenarios

| Concern | This assistant | Edge predictive inference | Existing AI remote access |
| --- | --- | --- | --- |
| Purpose | Answer questions using sanitized resources and bounded JSON observations. | Convert camera images into person detections. | Provide managed remote access to AI-related services. |
| Model | Generative Qwen text model. | Predictive YOLOX-Nano ONNX model. | Depends on the connected service. |
| MCP | Custom resource-read and MQTT services; optional camera and approved-publication actions. | None required. | Includes the built-in AIO MCP frontend access path. |
| Operator entry | Kubernetes-authenticated exec into the sample agent container. | Deployment tools and a read-only observation/file reader. | API Management and Azure Relay. |
| Data | Redacted resource metadata/spec/status and bounded JSON message samples. | JPEGs, prepared tensors, raw outputs, and detection JSON. | Requests to the configured remote service. |
| Ownership | Direct Kubernetes manifests; existing Foundry operator owns model reconciliation. | AIO Apps/ARM owns the native connector and pipeline resources; Kubernetes owns supporting resources. | See [the remote-access sample](../../ai/README.md). |

The custom-MCP and text-generation pattern comes from the Ignite agent scenario.
This extraction intentionally changes its operator transport: it does not reuse
the demo's MQTT chat request/reply topics or assume that a client-selected session
ID is caller authorization. The seven conversational tools are included;
unrelated application, scan, and learning components are not.

The custom resource service is not the built-in AIO MCP frontend with a different
URL. It has its own code, TLS identity, caller audience, tool definitions, and
Kubernetes RBAC. Built-in MCP role policies do not configure it.

## Model execution and action admission

The host uses a fixed seven-tool catalog, structured assistant/tool history,
one model-driven format correction, four model completions, temperature 0,
and a 256-token generation budget. `plant-telemetry` routes to `mq_messages`,
`camera-pan` to `mq_camera_pan`, and an approved `recommendation-publish`
request to `mq_publish`. Resource names are unchanged across the host and server.

The prompt requires tool evidence and distinguishes gate-state evidence from
person detections. The companion producer supplies only person detections,
not gate classifications. Topic bindings and action enablement come from
deployment settings. Neither prompt text nor a model-selected action can
override host/sidecar enablement or broker authorization.

The client preserves streamed `delta.content`. Native
`delta.tool_calls` do not override it, and reasoning prefixes are not trimmed.
`[DONE]` closes the stream. Finish reasons are additionally logged and returned
in `modelCompletions` for inspection, not rewritten or treated as a factual
acceptance gate. A plain-text answer can complete without
tool activity. This is **not** a claim that truncated, ungrounded, or internal
reasoning output is a valid operational answer.

Operator access uses Kubernetes-authenticated exec, MCP uses the SDK's HTTP
transport, and broker permissions target configured exact topics.
Telemetry accepts JSON objects, not arbitrary binary data.
Resource responses retain nested resource structure, with sensitive-key
redaction also covering connection strings. Malformed embedded
JSON and oversized resource strings fail rather than leaking or silently
truncating configuration.

Foundry 2.x uses `model.assetId`. Record the installed model-serving runtime
when investigating generation differences; a configured model name alone
does not identify the complete serving environment.

## Workloads and ownership

The default namespace is `aio-mcp-ai-assistant`.

| Resource | Responsibility |
| --- | --- |
| `Deployment/edge-assistant`, container `agent` | Loopback HTTP API, model/tool loop, pending approvals, and operator CLI. |
| Same Deployment, container `mqtt-mcp` | Loopback-only Streamable HTTP MCP endpoint, MQTT sampling/RPC/publication, and successful-key ledger. |
| `Deployment/edge-resource-mcp` | HTTPS Streamable HTTP MCP endpoint, TokenReview, and sanitized Asset/Device reads. |
| `Service/edge-resource-mcp` | ClusterIP port 443 to resource-MCP container port 8443. |
| `ModelDeployment/edge-assistant-qwen` | Dedicated generative model in the configured existing Foundry namespace. |
| cert-manager Issuers and Certificates | A sample-local CA and resource-service certificate. |
| Roles and bindings | Asset/Device read access, TokenReview creation, and get access to one named model deployment. |
| Optional `Deployment/edge-assistant-camera` and Service | Software ONVIF/RTSP camera with a synthetic panorama; owned by the sample helper. |
| Optional ARM ONVIF template, Device, and control Asset | AIO reconciles the native connector; ADR synchronizes the camera registration and managed actions. |

There is no Service for the agent or MQTT sidecar. Both bind to `127.0.0.1`.
NetworkPolicy denies inbound traffic to the agent Pod and limits the resource
service to agent Pods in the same namespace. The CNI must enforce those policies.
Egress is not restricted by this sample; site-specific policy must allow DNS,
the Kubernetes API, Foundry, and the broker.

The assistant Pods run as UID/GID 65532 with read-only root filesystems, no automatically
mounted service-account token, no privilege escalation, dropped capabilities,
and the runtime-default seccomp profile. Tokens are projected explicitly and
mounted only into the containers that need them.
The optional simulator runs as UID/GID 10001, uses generated credentials from
Secrets, and exposes only a ClusterIP Service. Its NetworkPolicy admits ONVIF
and RTSP TCP from the AIO or sample namespace; this requires an enforcing CNI.
Some native ONVIF images declare a named rather than numeric non-root user.
The optional [compatibility image](camera-actions.md#numeric-non-root-image-compatibility)
changes only that image metadata; AIO still owns the same native connector
runtime, credentials, allocation, and managed-action configuration.

## One question

1. `manage.py ask` checks sample Deployment ownership and invokes
   `aio-edge-assistant ask --stdin` with `kubectl exec`. It passes the question
   through stdin, not an interpolated shell command.
2. The CLI calls the Pod-local `/chat` endpoint. The host accepts a single
   question of 1-4000 characters and rejects a concurrent question.
3. Standard MCP initialization and `tools/list` run against both endpoints.
   Their exact tool names and input schemas must match the host's fixed catalog.
   Descriptions from a remote service do not replace the host's definitions.
4. For every model completion, the agent rereads the named
   `ModelDeployment.status.endpoints.internal` and projected Foundry token. It
   sends `/v1/chat/completions` with `stream: true`, the model ID, the conversation,
   and tool definitions. HTTPS certificate verification stays enabled.
5. The host strictly parses a single text tool call in `tool_parser.py`.
   A format error gets one model-driven correction turn, using the included
   correction instruction. A second format error, unknown tool, invalid
   arguments, or incomplete stream fails the question. Malformed calls are
   never executed or repaired by the host.
6. A permitted read or enabled camera call executes through the correct MCP service. The host appends
   a structured assistant `tool_calls` message and a matching `role: tool`
   message with the same `tool_call_id`. Tool results are not user instructions.
7. A recommendation request ends the question at the host's approval gate,
   without calling `mq_publish`. Otherwise, plain text ends the loop. The host returns the answer,
   executed calls/results, and completion finish reasons. The caller must
   independently verify evidence, complete output, and factual interpretation.

Tool markup must occupy exactly one complete block. Mixed prose, multiple
blocks, and malformed JSON enter the single format-correction path. A native
tool-call delta without any text content is unsupported, just as in the
reference text decoder. A `length` finish reason remains visible even if a
later SSE trailer reports `stop`; a token-limited final answer must not be
counted as successful acceptance. Record recovery of an intermediate format
failure separately rather than relabeling its original completion as clean.

SSE prevents the client from relying on a long nonstreaming response header
wait; it is not incremental user-visible chat. The CLI receives the final JSON
after the loop completes. The implementation uses no model SDK outside the
OpenAI-compatible HTTP contract.

Each question starts a new conversation. The host does not persist conversation
history, tool evidence, or answers. Operators may explicitly capture CLI output
according to their own access and retention requirements.

## Tool contracts

| Tool | Arguments | Result boundary |
| --- | --- | --- |
| `list_assets`, `list_devices` | Optional `limit`, 1-50, default 20; optional `name_prefix`, 1-63 characters. | Filter before limiting the returned list; `truncated` indicates omitted resources. No unbounded pagination. |
| `get_asset`, `get_device` | Required resource `name`. | One named resource in the configured AIO namespace. |
| `plant-telemetry` (remote `mq_messages`) | Optional `stage` and `machine_id`; `max_messages` 1-20, default 5; `timeout_ms` 100-5000, default 3000. | Select configured exact topics by stage and optional machine; return actual payloads and ISO-8601 receipt times. `machine_id` requires `stage`. |
| `camera-pan` (remote `mq_camera_pan`) | `direction`: left/right; optional integer `duration_seconds`: 1-6, default 2. | One configured Asset/profile; speed 0.35, device timeout, explicit Stop, and correlated final IDLE/position response. |
| `recommendation-publish` (remote `mq_publish`, after approval) | `idempotency_key` and a `recommendation` containing summary, severity, actions, and evidence. | The agent creates an expiring approval. Only operator approval calls the publisher; destination is a configured exact topic. |

Resources preserve `apiVersion`, `kind`, selected `metadata`, and redacted
`spec`/`status`. Annotations are omitted. Sensitive-key matching applies
recursively, including inside JSON-encoded configuration strings. This is not
a complete secret classifier: use secret references and authorized namespaces;
do not place credentials in arbitrary text. Kubernetes responses are limited
to 2 MiB and tool results to 256 KiB. Large namespace lists can exceed those
bounds; use a named-resource query rather than expecting unlimited collection.

For telemetry, no `stage` selects configured non-inference sources.
Stage `inference` selects only
inference bindings; omitting `machine_id` selects all bindings for the stage.
The legacy inference machine ID `ignite-camera` aliases `person`. An
unconfigured selector fails before connecting to the broker; it never creates
an arbitrary subscription. Configuration source keys are labels, not arguments.

MQTT uses MQTT 5, TLS, and enhanced authentication `K8S-SAT`. Each operation
opens a new connection and rereads the projected token. Ordinary
QoS 1 subscriptions can receive retained messages. Receipt time is not capture
time, and messages may be stale or duplicated. The sample does not deduplicate
or aggregate them.

Only UTF-8 JSON objects up to 64 KiB per message are accepted. Binary/JPEG,
oversized, malformed, duplicate-key, or unsupported payloads fail explicitly.
The full tool result must fit 256 KiB, so twenty near-limit messages cannot fit one
call. Request fewer messages or publish smaller observation objects.

### MQTT result

```json
{
  "topicFilter": "edge/predictive-inference/person/results",
  "messages": [
    {
      "topic": "edge/predictive-inference/person/results",
      "receivedAt": "2026-10-29T17:20:04.300000+00:00",
      "payload": {
        "status": "ok",
        "frameId": "illustrative-frame-id",
        "personCount": 1
      }
    }
  ],
  "count": 1,
  "timedOut": false
}
```

This abbreviated payload is illustrative. The tool preserves the publisher's
actual JSON object; it does not synthesize `status`, `frameId`, or `personCount`.
`timedOut: false` above assumes a requested message count of one.
If a stage selects several exact topics, `topicFilters` contains their list
instead of the single-topic `topicFilter`. This is the explicit configuration
extension; it does not grant a broader broker wildcard.

The sampling interval starts after subscription acknowledgement. Receipt time
does not prove publish or capture time; inspect producer timestamps and
correlation IDs. No received messages means no sampled evidence, not a healthy
pipeline, an empty area, or zero people. The companion sample's error topic
also does not cover every failure.

### Camera RPC

The model supplies direction and duration, never a camera URL, Asset name,
profile token, or MQTT destination. Those come from validated settings.
The sidecar serializes MQTT operations and subscribes to
`clients/edge-assistant-<namespace>/camera/response` before publishing.
Each action uses fresh MQTT 5 `CorrelationData`, the fixed `ResponseTopic`,
a 20-second message expiry, QoS 1, and no retention.

The native ONVIF connector subscribes to the control Asset's three managed-action
topics and translates their JSON arguments into ONVIF SOAP requests. The sidecar
checks each publish acknowledgement, then waits up to 20 seconds for its
correlated JSON response. A retained or unrelated response cannot satisfy
the current request. ONVIF errors and missing result fields fail explicitly.

After attempting `ContinuousMove`, the sidecar attempts `Stop` in a `finally`
block. A successful response also requires `GetStatus` to report `IDLE` and a
numeric pan position. Stop failure or network loss remains an error, not proof
that a physical device stopped. The simulator additionally honors the
device-side timeout in `ContinuousMove`.

### Recommendation approval and delivery

Both `/chat` and the direct `/tool` path return `approval_required` for an
enabled recommendation. The pending item contains a copy of the exact reviewed
arguments, a generated ID, and a 300-second expiry. There is no model-facing
approval tool. The operator uses the loopback `/approval` API through
authenticated exec to approve or deny; replacement arguments are not accepted.

Approvals are single-use, including when a publication attempt fails. Denial,
expiry, and disabled publishing do not call the MQTT service. There are at most
64 pending approvals per agent process. Approvals do not survive restart.

The sidecar independently validates enablement and the schema. Summary,
severity, action-list, and evidence-list sizes are bounded, and the encoded
payload must fit 16 KiB. It publishes only
`{"idempotencyKey": "...", "recommendation": {...}}` on the configured topic,
with QoS 1 and `retain: false`. A negative MQTT 5 PUBACK is an error, not a
successful publication.

Successful keys and payload hashes are retained for the sidecar process
lifetime, up to 1024 keys. A repeated matching key is a duplicate; different
content with the same key is rejected. Keys are not recorded after a rejected
publication. The ledger is neither durable nor shared across restarts.
A disconnect after broker acceptance can leave delivery uncertain; the
consumer must deduplicate for durable processing. PUBACK does not establish
consumer receipt or execution of the recommendation.

Approval is an application boundary for the model, not protection against
an administrator with Pod exec access. The agent and loopback MQTT sidecar
share a trusted Pod; such administrators can access the underlying MQTT identity.
Do not expose these loopback APIs or grant untrusted users exec access.

## Authentication and authorization

| Caller and destination | Authentication | Authorization |
| --- | --- | --- |
| Operator to Kubernetes | Operator's configured kubeconfig identity. | Read Deployment/Pod discovery and `pods/exec` in the sample namespace. |
| Agent to Kubernetes | Projected API token and cluster CA. | `get` only on the configured model deployment. |
| Agent to Foundry | Projected SAT with configured audience; Foundry CA. | `GeneralInferenceUser` for `edge-assistant` in the sample namespace, on the dedicated model only. |
| Agent to resource MCP | HTTPS; projected SAT with audience `edge-resource-mcp`. | TokenReview on each MCP HTTP request must return that audience and exactly `system:serviceaccount:<namespace>:edge-assistant`. |
| Resource MCP to Kubernetes | Its own projected API token and cluster CA. | Namespaced `get/list` on Assets/Devices; separate cluster permission to create TokenReviews. |
| Agent to MQTT MCP | Fixed loopback endpoint in the shared Pod. | Host and sidecar both enforce the fixed tool/source schemas. |
| MQTT MCP to broker | TLS; projected SAT with audience `aio-internal`. | Exact observation subscriptions; optional exact camera request/reply and recommendation Publish grants. |
| Native ONVIF connector to camera | The Device's credential references and camera authentication protocol. | The configured camera account and registered managed actions. |

The sample-local TLS CA is not installed as platform-wide trust. Only the public
`ca.crt` key of the resource service's certificate secret is mounted into the
agent; its server private key is not mounted there.

Changing the Foundry audience on a shared operator can break other applications.
Configure this sample to match the existing installation. Model authorization
and token audience validation are separate requirements.

The prompt describes tool results as untrusted evidence. This reduces accidental
instruction following but is not a guarantee against prompt injection or false
answers. Actual action admission comes from enablement, fixed tool schemas and
destinations, the host's publication-approval gate, constrained broker
permissions, and Kubernetes/model roles.
This is an operator sample, not a multi-tenant agent platform.

## Storage and failure boundaries

There is **no PVC in this assistant**. It does not read the predictive sample's
JPEGs, request tensors, or raw response files. Those remain governed by the
producer's own storage and cleanup behavior. Foundry may separately manage model
downloads/caches through the existing operator.
The simulator alone uses an `emptyDir` for PTZ state; it is not operational
history or durable evidence. The assistant does not mount that volume.

One question is limited to four completions and 300 seconds, including any
format-correction turn. An answer normally needs a completion after its last
tool call. A completion stream is limited to 1 MiB and each request specifies
256 generation tokens. Missing `[DONE]`, byte-limit overflow, and exceeding
the loop/deadline limits are errors. A `length` finish reason is a reported
generation limit, not proof of a complete answer. These bounds are not
availability or token-throughput guarantees.

Authentication, TLS, transport, tool, malformed-data, and model failures fail
the current question. The host never substitutes an empty success for a failed
tool. A legitimately quiet MQTT window is instead an explicit successful sample
with no messages and `timedOut: true`.

The host does not require retrieved evidence or semantically verify the final
answer. A completed response with a real tool trace can still make unsupported
claims; this occurred during the
[live model checks](operations.md#observed-model-limitations).
A failed question can also follow an already completed camera action. Error
responses do not guarantee a partial tool trace; inspect camera state and logs
before retrying rather than assuming that no movement occurred.

## Source map

| Behavior in the diagram | Implementation |
| --- | --- |
| Kubernetes ownership, explicit context, staged apply | [`manage.py`](../manage.py), [`deployment.py`](../src/aio_mcp_ai_assistant/deployment.py), [`kubernetes/`](../kubernetes/) |
| Local operator entry and response | [`cli.py`](../src/aio_mcp_ai_assistant/cli.py), [`server.py`](../src/aio_mcp_ai_assistant/server.py) |
| Discovery, validation, bounded tool loop | [`runtime.py`](../src/aio_mcp_ai_assistant/runtime.py), [`tools.py`](../src/aio_mcp_ai_assistant/tools.py) |
| Standard MCP transport and caller authentication | [`mcp_transport.py`](../src/aio_mcp_ai_assistant/mcp_transport.py) |
| Resource redaction, TokenReview, endpoint lookup | [`resources.py`](../src/aio_mcp_ai_assistant/resources.py) |
| Exact-topic sampling, correlated PTZ RPC, acknowledged publication | [`mqtt.py`](../src/aio_mcp_ai_assistant/mqtt.py) |
| Single-use operator approvals | [`approvals.py`](../src/aio_mcp_ai_assistant/approvals.py), [`runtime.py`](../src/aio_mcp_ai_assistant/runtime.py) |
| Software camera and native connector registration | [`simulator/`](../simulator/), [`kubernetes/simulator.yaml`](../kubernetes/simulator.yaml), [`bicep/`](../bicep/) |
| Streaming text inference and tool-call parsing | [`foundry.py`](../src/aio_mcp_ai_assistant/foundry.py), [`tool_parser.py`](../src/aio_mcp_ai_assistant/tool_parser.py) |
| Optional observation producer | [Edge predictive inference](../../edge-predictive-inference/README.md) |
