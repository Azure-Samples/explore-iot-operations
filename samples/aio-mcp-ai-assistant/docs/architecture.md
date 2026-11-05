# Architecture and contracts

This describes the [sample's](../README.md) configured architecture, not the
health or acceptance status of a running installation.

## Application and platform boundaries

The assistant is a client of **Microsoft's built-in AIO MCP frontend/backend**.
There is no custom Resource MCP Deployment, MQTT MCP sidecar, application
broker connection, or application-side AIO resource reader.

| Component | Responsibility and lifecycle |
| --- | --- |
| Operator CLI | Uses authenticated Kubernetes exec from outside the cluster. There is no public chat endpoint. |
| `Deployment/edge-assistant`, container `agent` | Loopback HTTP API, model/tool loop, frontend client, exact-topic application policy, and pending approvals. Created by the sample's Kubernetes helper. |
| Built-in AIO MCP frontend | HTTPS `/mcp`, projected-token authentication, role-filtered catalog, and forwarding to its backend. Existing platform installation; not created or upgraded by this sample. |
| Built-in AIO MCP backend | Resource tools and MQTT sampling/publication using its own Kubernetes and broker identities. Platform-owned. |
| Foundry Local | Dedicated Qwen text-model deployment, reconciled by the existing Foundry operator. Receives questions, metadata, and JSON, not camera images or tensors. |
| Camera-control data flow graphs, optional | Three `DataflowGraph` resources run custom WASM transforms that add MQTT RPC properties and invoke ONVIF managed actions. ARM/AIO owns deployment and execution. |
| Connector for ONVIF, optional | Converts managed-action MQTT requests into ONVIF SOAP. ARM/AIO owns its runtime. |
| Camera simulator, optional | Sample-owned Kubernetes workload with a synthetic panorama and software PTZ state. `emptyDir` state resets on Pod replacement. |
| Observation producer / recommendation consumer | Separate integrations. The assistant does not deploy them or automatically connect the simulator to an inference pipeline. |

Direct Kubernetes access in the agent exists only to resolve the named Foundry
`ModelDeployment.status.endpoints.internal`. It is not a fallback for AIO MCP
failures. The sample does not expose a built-in backend URL or fall back to
plaintext, arbitrary MCP services, direct broker access, or direct camera SOAP.

## One question

1. `manage.py ask` checks sample ownership and sends the question through stdin
   using `kubectl exec`. The CLI calls the Pod-local `/chat` endpoint.
2. The host discovers the built-in frontend catalog. It requires the tools and
   compatible parameter types used by this sample, not equality with the full
   platform catalog. Additional platform tools are **not exposed to the model**.
3. The host sends the question and its fixed seven-tool definitions to Foundry.
   The existing text-tool parser, correlated assistant/tool history, one
   model-driven format correction, four-completion limit, temperature 0, and
   256-token generation budget remain in place.
4. A valid tool call enters the application adapter. Resource reads, telemetry,
   and camera-control data flow graph messages all go through the built-in frontend.
   Invalid arguments or disabled actions fail before execution.
5. A recommendation proposal ends at the host's approval gate. Other tool
   results go back to the model; the CLI returns the answer and `toolActivity`.

Each question is independent and has a 300-second deadline. There is no
conversation history store. A plain-text answer can complete without evidence;
`completed` is not proof of factual correctness. Missing `[DONE]`, malformed
tool markup, or exceeded bounds fail explicitly. A `length` finish reason is
not converted into successful completion or repaired output.

The MCP SDK handles Streamable HTTP, SSE, sessions, and protocol initialization.
The client follows bounded catalog pagination (256 tools/256 pages), rereads the
projected token for each session, requires TLS verification, and refuses redirects. Responses are
bounded to 512 KiB before parsing. Tool results must fit 256 KiB and contain an
object in `structuredContent` or a single JSON text item; `isError` never
becomes an empty success.

## Tool mapping

| Model-facing tool | Built-in implementation | Application constraints |
| --- | --- | --- |
| `list_assets`, `list_devices` | `aio_list_assets`, `aio_list_devices` | Host applies optional name prefix and a 1-50 result limit to the returned name/description map. |
| `get_asset`, `get_device` | `aio_get_asset` with `asset`; `aio_get_device` with `device` | One validated name; return the platform's redacted configuration under `item`. |
| `plant-telemetry` | `aio_mq_messages` | Stage/machine selection maps only to configured concrete topics; 1-20 returned messages and a 100-5000 ms window. |
| `camera-pan` | `aio_mqtt_publish` plus `aio_mq_messages`, through camera-control data flow graphs | Configured Asset/ONVIF media profile; left/right at speed 0.35 for 1-6 seconds; explicit Stop and verified IDLE. |
| `recommendation-publish` | Host approval, then `aio_mqtt_publish` | One configured topic, bounded 16 KiB payload, single-use operator approval, process-local deduplication. |

`camera-check` is an operator command, not an additional model-facing tool.
It publishes a GetStatus request through the bridge and requires a real
correlated IDLE response. It never requests movement.

### Resource results

Built-in list tools return resource names mapped to descriptions (or `true`
when no description is available). The adapter returns:

```json
{
  "items": [{"name": "example-camera", "description": "Illustrative camera"}],
  "count": 1,
  "truncated": false
}
```

Named reads return the backend's configuration under `item`; they do not
reconstruct the old Kubernetes `metadata/spec/status` envelope. Use named reads
for device references and other details, rather than assuming list entries
contain them.

Sensitive-key redaction covers nested objects and JSON-encoded configuration
strings, including connection strings. Annotations are omitted. Malformed
embedded JSON or oversized resource strings fail rather than being silently
truncated. This is not a complete secret classifier: use secret references,
not credentials in arbitrary text.

### Observation results

The built-in sampler does not include originating topics or per-message receipt
timestamps. The adapter samples **each concrete topic separately**, decodes
`UTF8` JSON or `Unspecified` base64 JSON, and labels the result with that
known topic. It never invents the origin of a wildcard match.

`sampledAt` is the agent-side sample completion time, not publication, receipt,
or camera capture time. Inspect producer timestamps and frame identifiers.
Retained, delayed, or duplicate messages can occur; the sample does not infer
freshness from arrival or aggregate frame counts into unique-person counts.

Only JSON objects up to 64 KiB per message are accepted. Missing format
indicators, malformed JSON/base64, duplicate JSON keys, binary images, and
oversized payloads fail explicitly. Empty windows return `messages: []`,
`count: 0`, and `timedOut: true`; they do not prove an empty scene or a healthy
pipeline. When multiple topics are selected, they are sampled concurrently and
the combined result is capped at the requested count; ordering is by configured
topic, not a synchronized frame timeline.

No `stage` selects configured non-inference sources. A specified stage selects
only its bindings; optional `machine_id` narrows them. The legacy inference
machine ID `ignite-camera` aliases `person`. Source names are configuration
labels, not tool arguments. Unknown selectors fail without subscribing.

## Camera-control data flow graphs

The built-in `aio_mqtt_publish` accepts topic and JSON payload, but cannot set
MQTT response-topic or correlation properties. The three
[camera-control data flow graphs](../native-camera-actions/README.md) bridge that gap.
Each `DataflowGraph` has an MQTT source, a custom WASM transform, and an MQTT
destination. The transform's graph definition references a WASM module that
uses `wasm_graph_sdk::command_invoker`; it is **not another MCP server**.

The path is:

```text
Agent -> built-in MCP frontend/backend -> MQTT broker -> data flow graph
Data flow graph -> MQTT broker -> connector for ONVIF -> camera SOAP
ONVIF managed-action response -> MQTT broker -> data flow graph
Data flow graph -> MQTT broker -> MCP frontend/backend -> agent
```

Each action has a separate data flow graph so a blocked Move invocation cannot
serialize Stop behind it. The application publishes one request, with a UUID and whole
Unix-second `issuedAt`, to `<topicPrefix>/requests/<Action>`. The graph returns
the actual ONVIF managed-action result or an explicit error on the corresponding
response topic. The Asset and ONVIF media profile come from graph configuration,
not model input.

The agent starts response sampling before publication, allowing two seconds
for subscription establishment. The frontend provides no subscription-ready
acknowledgement; this delay is not a delivery guarantee. Missing replies time
out explicitly. Matching replies must agree on request ID, action, Asset,
ONVIF media profile, and timestamp and must not be stale. Managed-action responses
require `Result` and no `Error`.

The agent verifies initial IDLE, submits a finite ContinuousMove once, attempts
Stop, then verifies GetStatus and a finite normalized pan position. If motion
delivery or the first Stop/verification is uncertain, it holds its camera lock
for a further 12-second fence, then Stops and checks again. The fence covers
graph Move input age (5 seconds), allowed future clock skew (5 seconds), and
ONVIF Move RPC expiry (2 seconds). Recovery does not turn the failed operation
into success. If stopped state remains unconfirmed, new motion is blocked
until an operator reconciles the camera/queues before restarting the agent.

This conversational sample does not deploy Ignite's separate scan worker,
durable camera ownership, gate analysis, or continuous scan workflow. Its camera
lock and admission state are process-local. Do not run competing camera
controllers. Network loss or process termination can prevent Stop; the
device-side timeout and physical safeguards remain necessary.

## Approval and delivery

Both chat and direct `recommendation-publish` requests create a copied,
single-use approval with a 300-second expiry. Only the operator's separate
`approve` command can consume it and call the publisher. There is no
model-facing approval tool; denial, expiry, and disabled publishing send nothing.
At most 64 approvals are pending per agent process.

The built-in publish tool uses QoS 1, nonretained messages, and checks the
broker PUBACK. A successful tool call confirms broker acceptance, not consumer
delivery or execution of the recommendation. Use an independently authenticated
consumer and deduplicate `idempotencyKey`.

The adapter remembers at most 1024 successful key/payload hashes. Same
key/same payload suppresses duplicate publication; changed content with the
same key fails. Failed calls do not record success. Approvals and this ledger
disappear on restart; ambiguous delivery is not automatically retried and
must be reconciled with the consumer.

## Identity and authorization

| Caller | Authentication and authorization |
| --- | --- |
| Operator to agent | Kubernetes identity with sample Deployment/Pod access and `pods/exec`. Exec is privileged access, not per-user production chat authorization. |
| Agent to frontend | AIO CA and projected token with the frontend's inbound audience, normally `aio-mcp-frontend`. ServiceAccount annotation `aio-mcp-auth/roles` grants Reader/DataReader; camera graph configuration or enabled recommendations additionally require Admin. |
| Frontend/backend to AIO | Existing platform identities and configuration. Backend resource visibility and broker permissions are not replaced by this sample. |
| Agent to Kubernetes | Separate projected API token; get only on one named Foundry ModelDeployment. No Asset/Device or TokenReview permission. |
| Agent to Foundry | Separate audience/token and CA; dedicated model authorizes only the sample service account. |
| Data flow graph / connector for ONVIF | Platform-managed broker identities; managed-action RPC and camera credentials remain with AIO. |

**Admin grants more tools than the model can call.** The application allowlist
does not narrow that credential, and approved topic inventory is not a
per-agent broker ACL. Protect tokens, ServiceAccount annotations, exec access,
the shared frontend policy, and the backend identity.

The agent binds only to loopback, has no Service, and runs non-root with no
capabilities, read-only root filesystem, explicit token projections, and
inbound-deny NetworkPolicy. Enforcement depends on the CNI. The sample does
not restrict egress or certify cluster-wide isolation.

## Storage and source map

No assistant PVC stores images, tensors, observations, or conversation history.
Foundry manages its own model cache. The simulator's temporary state and graph
deduplication ledgers are not durable operational evidence.

| Behavior | Implementation |
| --- | --- |
| Explicit-context deployment, roles, ownership, legacy cleanup | [`deployment.py`](../src/aio_mcp_ai_assistant/deployment.py), [`kubernetes/`](../kubernetes/) |
| Operator entry | [`manage.py`](../manage.py), [`cli.py`](../src/aio_mcp_ai_assistant/cli.py), [`server.py`](../src/aio_mcp_ai_assistant/server.py) |
| Model/tool loop and approvals | [`runtime.py`](../src/aio_mcp_ai_assistant/runtime.py), [`tools.py`](../src/aio_mcp_ai_assistant/tools.py), [`approvals.py`](../src/aio_mcp_ai_assistant/approvals.py) |
| Built-in MCP protocol client | [`mcp_transport.py`](../src/aio_mcp_ai_assistant/mcp_transport.py) |
| Resource adaptation, observations, publication, camera policy | [`frontend.py`](../src/aio_mcp_ai_assistant/frontend.py) |
| Camera-control WASM modules and data flow graph deployment | [`native-camera-actions/`](../native-camera-actions/), [`camera-actions.bicep`](../bicep/camera-actions.bicep) |
| Model endpoint lookup and streaming inference | [`kubernetes.py`](../src/aio_mcp_ai_assistant/kubernetes.py), [`foundry.py`](../src/aio_mcp_ai_assistant/foundry.py) |
| Separate vision producer | [Edge predictive inference](../../edge-predictive-inference/README.md) |
