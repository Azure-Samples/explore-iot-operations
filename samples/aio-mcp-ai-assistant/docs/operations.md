# Operations, troubleshooting, and cleanup

Run commands from `samples/aio-mcp-ai-assistant` with the virtual environment
active and the original populated configuration available. Initial setup and
direct run commands are in the [scenario README](../README.md).

## Readiness is not an end-to-end check

```bash
python manage.py status config.json
python manage.py check config.json
```

The agent's `/readyz` checks the MCP catalogs and the named model's internal
endpoint. It does not make a broker subscription or run inference. Its
`modelInferenceVerified` and `mqttSubscriptionVerified` fields are always false
for this check, even if an earlier question succeeded.

The MCP services' readiness endpoints check process/configuration availability.
They are not proof that Asset/Device reads, topic access, a running observation
producer, or the model work end to end.

Validate those separately:

```bash
python manage.py tool config.json list_assets '{"limit":2}'
python manage.py tool config.json plant-telemetry \
  '{"stage":"inference","machine_id":"person","max_messages":1,"timeout_ms":5000}'
python manage.py ask config.json "List up to two assets using the resource tool."
```

Direct tools still verify both MCP catalogs, but they do not call the text model.
They are the first place to separate a dependency/data issue from a model
interpretation issue.

## Observed model limitations

**Model-assisted acceptance is partial.** The configured CPU model can select
and explain a camera action, but it has not passed the recommendation-proposal
flow. It can also omit requested observation fields. Successful direct tools
do not establish reliable model selection or interpretation.

The recorded action checks used `qwen3.5-2b-text-generic-cpu:1` with Foundry
runtime `generative-py-cpu:2.261102.2`, temperature 0, 256 generation tokens,
four completions maximum, and one model-driven format correction. No GPU,
model-output repair, or substituted tool result was used.

| Path | Observed result and qualification |
| --- | --- |
| Direct camera actions | Left and right pans traversed the real MCP service, broker, and native ONVIF connector. Independent SOAP reads matched final `IDLE` positions, and actual simulator snapshots changed. Invalid duration was rejected without movement; an invalid-profile RPC surfaced the native ONVIF fault. |
| Model-selected camera | The model called `camera-pan` once with left/one-second arguments and correctly reported the confirmed stop and `-0.35` position. Both completions terminated normally. |
| Direct recommendation workflow | No delivery before approval or after denial/expiry. An independently authenticated subscriber received the exact approved JSON. Reused approvals were rejected, duplicate successful keys did not republish, and a forbidden-topic publish returned MQTT reason 135 (`Not authorized`). |
| Model-generated recommendation | **Did not pass.** Observed failures included invalid nested argument types, malformed recommendation JSON, and a plain-text answer without a proposal. Another resource/recommendation question lost its stream when Foundry's liveness probe restarted the serving container. None produced an approved model-generated publication. |
| Observation interpretation | Classification and empty-window checks passed, but a two-frame answer omitted requested frame IDs despite reporting the correct individual counts. Check every requested field against `toolActivity`. |

These are integration checks, not a hardware or production qualification.
The camera and movement were simulated; recommendation/telemetry fixtures were
explicitly synthetic. Resource checks used actual registrations, including
fictional equipment and the software camera. No physical camera or
media/person-detection pipeline was exercised by these action checks.
The native connector required the documented
[numeric-user packaging workaround](camera-actions.md#numeric-non-root-image-compatibility);
its official filesystem and entrypoint were unchanged.

The tested authorization policy covered TLS listener **18884**. Another existing
listener, **18883**, had no authorization policy, and the validation cluster did
not enforce NetworkPolicy. Those checks do **not** establish cluster-wide
isolation. Protect every reachable listener and use an enforcing CNI in your
own deployment.

### Accept a model-assisted result

Record the actual model, runtime, and compute. Verify all of the following
independently of the loop's `status`:

1. The actual serving Pod has loaded the requested model on the intended
   compute, rather than merely showing an available endpoint.
2. The question causes the requested permitted tool call. Its returned resources,
   messages, or action state match independent API, producer, or camera evidence.
3. The final answer is complete public text without invented tool results or
   internal/control markup, and correctly interprets the returned evidence.
4. A recommendation has `approval_required` and a real approval ID before any
   publication. Review its evidence and exact payload; only an independent
   consumer can confirm delivery after approval.
5. `modelCompletions` exposes every finish reason. A `length` followed by
   `stop` is still a token-limited completion, not a clean success. Reject a
   token-limited final answer. If the permitted format correction recovers an
   intermediate failure, record that recovery separately; it does not make
   the original completion clean.

An ungrounded plain-text answer can complete without a tool read. Do not accept
it as an operational result. Use the documented direct tools when exact data or
a reproducible approval workflow is required; that is an explicit operator
choice, not an automatic model fallback. Malformed tool arguments are not repaired
or executed.

If a chat fails after camera movement, the error may not contain the earlier
tool activity. Inspect the camera state and connector/simulator logs before
retrying; failure of the final answer does not undo a completed action.

## Connect the actual components

Local test doubles are confined to `tests/`; do not copy their scripted model
answers, fixture assets, fake tokens, or replaced MQTT client into a deployed
application. The [mock inventory](../README.md#real-components-mocks-and-replay-inputs)
identifies each boundary. Use the following steps to exercise real dependencies.

### Connect resource queries to AIO

Use an actual AIO installation with the namespaced Asset and Device APIs.
Register your equipment through the platform's supported asset/device management
path or use existing registered equipment; a fixture copied into a test is not
a registered device. Set `kubeContext` and `aioNamespace` in `config.json` to
that installation.

After completing the README's deployment steps, run:

```bash
python manage.py tool config.json list_assets '{"limit":5}'
python manage.py tool config.json list_devices '{"limit":5}'
```

Use names returned by those calls with `get_asset` and `get_device`, and compare
the sanitized fields with the same resources in AIO or the Kubernetes API. Empty
lists are valid only when the real namespace has no corresponding resources;
they do not demonstrate access to a configured piece of equipment.

### Connect the agent to a real Foundry model

Follow the platform's
[Foundry Local Arc-extension installation guide](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
for Gateway API, Istio, cert-manager/trust-manager, and the inference operator.
This is the Kubernetes deployment, not desktop Foundry Local. Reuse compatible
prerequisites instead of installing competing controllers. Restrict trust-manager
Secret targets to the required Foundry CA bundle where supported.

Set `foundry.namespace`, `catalogName`, `catalogVersion`, and `compute` to the
actual installation/model. Foundry 2.x also requires `foundry.assetId`, the exact
versioned Azure ML catalog ID. The sample renders `spec.model.assetId` when set,
or the legacy `spec.model.catalog` only when omitted. Keep the ID's model name
and version consistent with the chat model configuration; `latest` is not a
pinned asset version. For GPU inference, also set `nodePool` and verify that
the selected node advertises `nvidia.com/gpu` after driver/device-plugin setup.
Match `tokenAudience` to the existing installation and configure its public CA
ConfigMap/key; do not replace TLS verification with an insecure HTTP client.

Complete [identity, broker authorization, and workload deployment](../README.md#deploy-the-scenario),
then call the real model through the agent:

```bash
python manage.py check config.json
python manage.py ask config.json \
  "List up to five configured assets and identify their device references."
```

Confirm that the result names the selected model and contains a real
`list_assets` call with matching metadata. For a GPU result, also inspect the
serving Pod's GPU allocation and runtime GPU use; a GPU-capable VM alone is not
proof the model ran on the GPU. Readiness and local SSE tests do not replace
these checks.

### Replace synthetic telemetry or camera replay

For the predictive scenario, follow the companion sample's
[deployment prerequisites](../../edge-predictive-inference/docs/deployment.md#prerequisites)
and [deployment sequence](../../edge-predictive-inference/README.md#deployment-and-operations).
Configure its `cameraUrl` for an authorized physical RTSP camera and use its
secret-backed `cameraAuthentication` settings. Do not embed credentials in a URL.
Deploy the real media connector, AIO Apps-managed inference connector, graph,
model, and shared storage as described there.

A replay can exercise those same real components, but the camera input is still
recorded or simulated. Label it as a replay in validation results and do not claim
live capture, occupancy, or physical-camera qualification. A synthetic JSON
publisher bypasses the camera and predictive pipeline entirely.

Once the actual producer is publishing:

1. Read its real result/error topics using the producer's reader and verify
   frame IDs, timestamps, and its documented output contract. For tensor
   correlation, use the producer's
   [input/output inspection steps](../../edge-predictive-inference/docs/deployment.md#inspect-the-model-input-and-output);
   the assistant does not mount that storage.
2. Set this sample's `sources` to the exact `<topicPrefix>/results` and
   `<topicPrefix>/errors` topics from the producer's configuration. Bind them
   to stage `inference` / machine ID `person` and stage `errors` / machine ID
   `person`, respectively. Replace
   validation-topic names and synthetic source descriptions. Do not send raw
   JPEGs or tensors to the text model.
3. Run `python manage.py render config.json`. Have the broker owner review the
   generated rule, authorize those exact subscriptions on the configured TLS
   port, and remove obsolete validation-topic grants. Preserve other clients'
   policies and ports.
4. Run `python manage.py workloads config.json`, then collect real messages and
   ask an independent model question:

```bash
python manage.py tool config.json plant-telemetry \
  '{"stage":"inference","machine_id":"person","max_messages":2,"timeout_ms":5000}'
python manage.py ask config.json \
  "Use plant-telemetry with stage inference and machine_id person to read up to two messages. Report each frameId and personCount separately, with receivedAt. Do not sum counts across frames."
```

Compare the answer with the exact messages in that question's `toolActivity`,
not an earlier sampling window. An empty error window must remain "no messages
observed in this window," never a healthy-pipeline or zero-person conclusion.

If a validation fixture publisher is used before the real producer is ready,
identify its payloads as synthetic, use distinct validation-only topics, and
record that the camera/predictive pipeline was not exercised. Stop that publisher
before qualifying the real producer. No synthetic source is automatically
substituted when a real dependency fails.

## Inspect logs and events

Read only nonsecret configuration values into shell variables:

```bash
CONTEXT=$(python -c 'from aio_mcp_ai_assistant.config import load_settings; from pathlib import Path; print(load_settings(Path("config.json")).kube_context)')
NAMESPACE=$(python -c 'from aio_mcp_ai_assistant.config import load_settings; from pathlib import Path; print(load_settings(Path("config.json")).namespace)')
FOUNDRY_NAMESPACE=$(python -c 'from aio_mcp_ai_assistant.config import load_settings; from pathlib import Path; print(load_settings(Path("config.json")).foundry.namespace)')
MODEL=$(python -c 'from aio_mcp_ai_assistant.config import load_settings; from pathlib import Path; print(load_settings(Path("config.json")).foundry.deployment_name)')

kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods
kubectl --context "$CONTEXT" -n "$NAMESPACE" get events --sort-by=.lastTimestamp
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs deployment/edge-assistant -c agent --tail=100
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs deployment/edge-assistant -c mqtt-mcp --tail=100
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs deployment/edge-resource-mcp --tail=100
kubectl --context "$CONTEXT" -n "$FOUNDRY_NAMESPACE" describe modeldeployment "$MODEL"
```

Use the model deployment's status and the platform owner's documented workload
selection to find its serving logs. Do not assume a generated model Pod name.
Logs and returned evidence can contain operational information; apply access
controls and retention policies before sharing them.

| Symptom | Check |
| --- | --- |
| `prepare` refuses an existing resource | Namespace and sample-instance ownership labels. Choose a new namespace/model name rather than adopting unrelated resources. |
| Missing CRDs or incompatible API version | Required preview installation and the registered `v1` APIs. This sample does not install AIO, Foundry, or cert-manager. |
| Invalid/missing CA data | ConfigMap namespace/name/key and PEM contents. The bundle must trust the actual endpoint. Do not disable TLS verification. |
| Certificate does not become Ready | cert-manager controllers, Certificate/Issuer events, secret-name conflicts, and admission/network restrictions. |
| `ImagePullBackOff` | Published image/version, architecture, and registry pull secret in the sample namespace. The model's catalog access is managed separately by Foundry. |
| Simulator image pull says `insufficient_scope` | The registry credential must cover the simulator repository as well as the assistant repository. The native connector's optional private-image pull Secret belongs in the AIO namespace. |
| Native ONVIF Pod rejects named user `nonroot` | Use the [numeric-user compatibility image](camera-actions.md#numeric-non-root-image-compatibility) or a validated compatible official release. Do not disable non-root enforcement or patch controller-owned Pods. |
| Resource MCP 401/403 | Projected token audience `edge-resource-mcp`, exact caller service-account namespace/name, TokenReview API reachability, and resource service permissions. |
| Resource tool 403 | Reader Role/RoleBinding in `aioNamespace`; namespaced Asset/Device API group and version. |
| Unknown asset/device | Use `list_assets`/`list_devices`; configured names and resource namespace must match. A Kubernetes 404 is not an empty success. |
| MQTT connection or subscription rejected | TLS listener, SAT audience `aio-internal`, service-account authorization attribute, attached authorization policy, Connect grant, and exact Subscribe topics. |
| MQTT sample is empty | Producer enabled/running, exact topic/prefix, publication interval, backlog, and configured sampling window. Silence alone cannot locate a fault. |
| Invalid or oversized MQTT payload | Select a bounded JSON-object observation topic, not JPEGs/tensors. Payload limit is 64 KiB; the total result limit is 256 KiB. |
| Camera or publishing action disabled | Set only the intended action's enablement flag, review the generated exact-topic rule, and redeploy. An enablement flag alone does not grant broker access. |
| Camera RPC times out or returns an ONVIF fault | Device/Asset synchronization, native connector readiness, camera credentials/profile, all three managed actions, request/reply grants, and camera connectivity. A timeout does not prove that motion stopped. |
| Approval missing, expired, or already consumed | IDs are single-use, expire after 300 seconds, and are lost on agent restart. Review a new request rather than trying to reuse or modify an old approval. |
| MQTT publication rejected | Inspect the negative PUBACK and the exact Publish grant on the configured listener. Reason 135 means `Not authorized`; it is not successful delivery. |
| Published but consumer saw nothing | PUBACK confirms broker acceptance only. Check the consumer's separate identity, subscription acknowledgement, topic, connection window, and deduplication. Messages are not retained. |
| Foundry 401/403 | Existing gateway audience, model authorization for this agent service account, and the separate dedicated model resource. |
| No internal model endpoint | Model download/startup, catalog access, compute/memory availability, and installed operator compatibility. |
| `model.catalog is no longer accepted` | Set `foundry.assetId` from the Foundry 2.x catalog, matching `catalogName` and `catalogVersion`, then rerender and rerun `model`. Do not downgrade the shared operator just to retain an obsolete manifest. |
| Model completion truncated/unsupported | Inspect `modelCompletions`, model logs, and the actual public answer. The reference decoder preserves text until `[DONE]`; it does not convert `length` into a clean finish or repair truncated tool calls. Do not count this as an acceptance pass. |
| `Tool call contains invalid JSON` | The single model-driven format correction also failed. Compare with a direct tool call to isolate model generation from MCP transport; do not trim braces or execute partial arguments. |
| Recommendation arguments fail object/array validation | The model did not satisfy the nested schema. No approval or publication is created. Use the explicit direct proposal workflow if needed; do not coerce malformed model output into an action. |
| Incomplete streamed response and serving-container restart | Check Foundry Pod events, previous logs, liveness failures, and CPU/memory pressure. Wait for recovery and inspect any earlier action before retrying. Do not disable health checks to conceal the failure. |
| Completed answer contradicts the tool result | `completed` is not a semantic correctness guarantee. Inspect `toolActivity`; an empty error-topic window is neither zero detections nor evidence of a healthy pipeline. |
| Model answered without evidence | The reference loop can return plain text without a tool read. Inspect `toolActivity`, reject it as operational acceptance, and use a concrete question naming an available tool and stage/machine binding. |
| Catalog/schema mismatch | Deploy matching images and configuration to both Deployments and both agent containers; do not mix independently changed tool versions. |
| Busy or deadline exceeded | One active question per instance; four completions maximum, including any format-correction turn. Allow it to finish and narrow the next question. Inspect CPU pressure and Foundry latency. |

If the workload rollout times out while the model is downloading, inspect the
model first. Once the dependency is ready, rerun `workloads`. Do not replace
readiness checks with always-successful probes.

When replacing a model, `Available=True` and an updated observed generation
can appear while the old model still serves and new files are downloading.
Wait for the actual serving Deployment's model/version and compute template,
its completed rollout, and runtime confirmation that the requested model loaded.
Do not delete the old compute pool based only on the ModelDeployment condition.

## Observation interpretation

The model receives the actual JSON payloads on your approved topics. The
companion predictive sample supplies additional semantics:

- `status: "ok"` identifies successful frame-level inference. A
  `personCount` of zero means no qualifying detections, not proof of no people.
- `status: "error"` is not a successful zero count. The error topic does not
  cover every preprocessing, inference, or transport failure.
- `frameId` correlates a processing attempt, not a persistent person identity.
  Do not sum counts across frames or claim unique-person tracking.
- MQTT receipt time is not camera capture time. Delayed or duplicate delivery
  can affect an apparent "latest" observation.

There is no historical store, occupancy calculation, or unattended control loop.
Enabled camera actions require an operator request; recommendation publication
requires a separate approval. A publication does not execute its suggested
actions. Ordinary subscriptions can include retained messages, so inspect
producer timestamps rather than treating receipt as fresh capture. The prompt
is not a schema-aware validator for every producer; inspect the trace and the
producer's output contract.

## Updates and rotation

Keep namespace, model identity, and source topics stable during an ordinary
application update. Use a new image version rather than overwriting a deployed
tag:

```bash
# Edit image/version or source descriptions in config.json first.
python manage.py render config.json
python manage.py build config.json
python manage.py push config.json
python manage.py workloads config.json
```

The settings checksum triggers a rollout for changed configuration; changed
image references also update the Pod template. Both MCP services must converge
on the same tool schemas. Transient discovery failures during rollout are
expected; retry after both Deployments are ready. The single agent Pod uses a
Recreate update strategy, so an update interrupts an in-flight question.
Agent restart discards pending approvals; sidecar restart clears the in-memory
publication ledger. Check the consumer before resubmitting a previously approved
recommendation. Simulator image changes additionally require
`python manage.py simulator config.json`; replacing its Pod resets PTZ state.
Native connector and Device/Asset changes use their ARM templates, not
`manage.py workloads`.

Topic changes also require the broker owner to review and merge the new
generated rule, and remove obsolete permissions. Changing a model name or
namespace creates a different resource set; it is not migration or cleanup.
Retain the previous configuration if those resources must be removed.

Projected API, Foundry, resource-MCP, and broker tokens are reread for requests
or new sampling connections. Public broker/Foundry CA bundles are **copied** at
`prepare`; they are not continuously synchronized. The resource-MCP server also
loads its serving certificate at startup.

After an owner-coordinated CA/certificate rotation, refresh the copied trust
and explicitly restart both sample Deployments:

```bash
python manage.py prepare config.json
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout restart deployment/edge-resource-mcp deployment/edge-assistant
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment/edge-resource-mcp --timeout=180s
kubectl --context "$CONTEXT" -n "$NAMESPACE" rollout status deployment/edge-assistant --timeout=180s
python manage.py check config.json
```

Use overlapping trust where your platform requires it. Do not change the
shared operator audience, discard platform CAs, or copy server private keys to
the agent to resolve a trust failure. Review the sample-local CA lifecycle with
the cert-manager owner; these manifests are not a general certificate-rotation
system.

## Stop and remove this instance

Stop issuing requests and disable optional actions. If the camera tutorial was
deployed, first remove its owned Azure Device/control Asset using the
[camera cleanup steps](camera-actions.md#clean-up). Then run:

```bash
python manage.py cleanup config.json --yes
```

The helper verifies both `app.kubernetes.io/part-of` and
`app.kubernetes.io/instance` before deleting any target. It deletes explicitly
named sample resources, including the dedicated Qwen model and the sample's
cross-namespace/cluster RBAC bindings. It does not recursively delete a namespace.
With the original `simulator` configuration present, it also removes the owned
simulator workload and camera credential Secrets in both namespaces.

The namespace, registry credentials and images, broker policy, AIO installation,
Foundry operator, cert-manager, and all predictive-inference resources remain.
Foundry-owned caches or retained storage follow the installed operator's
policy; inspect them with the platform owner if further cleanup is required.
Have the broker owner remove only this instance's authorization rule.
The optional native connector template and its registry pull credentials are
not removed by this helper; retire them only after checking for other users.

Separately provisioned node pools and added broker ports are not removed by the
helper either. After checking for other workloads and clients, have the platform
owner retire only the unneeded sample capacity and port. Nodes continue accruing
charges until stopped or removed.

If an object was deliberately transferred to another owner, do not relabel it
merely to force cleanup. Resolve ownership and dependencies explicitly.

## Related documentation

- [MQTT broker authentication](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authentication)
- [MQTT broker authorization](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authorization)
- [Companion predictive-inference operations](../../edge-predictive-inference/docs/operations.md)
- [Existing AI remote-access sample](../../ai/README.md)
