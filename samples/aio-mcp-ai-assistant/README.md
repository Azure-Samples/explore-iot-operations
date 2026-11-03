---
page_type: sample
description: Use custom MCP services and Foundry Local to explain Azure IoT Operations resources and observations, pan a simulated camera, and publish operator-approved recommendations.
languages:
- python
products:
- azure-iot
- azure-iot-operations
---

# AIO MCP and AI: edge operations assistant

Ask natural-language questions about equipment configured in Azure IoT
Operations (AIO) and the observations published by your edge applications.
This sample runs an assistant on the edge cluster, using a Foundry
Local text model and two custom **Model Context Protocol (MCP)** services.

The assistant can retrieve Asset and Device configuration, read recent JSON
messages from approved MQTT topics, and explain the results. Each response
includes the tool calls and data behind the answer so that an operator can
inspect the evidence.

Start with read-only questions, then optionally enable two bounded actions:
pan an ONVIF camera simulator, and publish a recommendation **only after an
operator approves it**. Both actions are disabled in the default configuration.

**Use the sample:** [Scenario](#scenario) | [Architecture](#architecture) |
[Prerequisites](#prerequisites) | [Build](#build-and-test-locally) |
[Configure](#configure-the-instance) | [Deploy](#deploy-the-scenario) |
[Run](#run-and-observe) | [Validate](#validate-the-integrations) |
[Camera actions](docs/camera-actions.md) |
[Clean up](#stop-and-clean-up).

> [!IMPORTANT]
> **Compatible preview environment required.** Foundry Local here is the
> Kubernetes operator with `ModelDeployment` and generative-model support, not
> the desktop application. Confirm the [prerequisites](#prerequisites) before
> deploying. These are custom MCP implementations included in this sample,
> **not the built-in AIO MCP frontend**; enabling that frontend is not required.

This is an evaluation sample, not an autonomous monitoring or safety system.
Review the [limitations](#limitations) before using its answers operationally.

## Scenario

A camera overlooks a workcell. A person-detection pipeline publishes a result
for each successfully processed image, while AIO stores the camera's Asset and Device
configuration. An operator needs to answer three different questions: what is
configured, what the detector recently reported, and whether any processing
errors were observed.

This sample adds a conversational interface to those existing data sources:

| Operator request | What happens |
| --- | --- |
| Which assets are configured, and which devices do they reference? | Asset and Device resources in the configured AIO namespace. |
| Which streams or datasets are configured on this asset? | The named resource's configuration, with sensitive fields redacted. |
| What do recent person-detection messages report? | A bounded sample of JSON messages from the configured results topic. |
| Were any processing errors reported during the sample window? | Messages from the configured error topic, or an explicit empty result. |
| Pan the simulated camera right for two seconds. | Sends bounded PTZ commands through the real broker and ONVIF connector, explicitly stops, and checks the returned position and `IDLE` state. Requires camera enablement. |
| Prepare a recommendation for an operator to review. | Returns the proposed JSON and an expiring approval ID. Only a separate operator approval can publish it to the configured MQTT topic. Requires publishing enablement. |

Use the [edge predictive inference sample](../edge-predictive-inference/README.md)
to supply the camera observations. Its media connector, data flow, native
inference connector, and YOLOX-Nano model produce frame-level person detections.
The assistant reads that **result JSON**; it does not process images or run the
person-detection model.

You can start with resource questions without deploying the camera pipeline.
For observation questions, connect the companion pipeline or another authorized
JSON publisher. The assistant does not generate sample observations when a
producer is unavailable.

### What you will deploy and run

By completing this scenario, you will deploy the assistant and its two MCP
services, deploy a dedicated text model, and run questions against your own
resource metadata and MQTT observations. You will also call the tools directly
to compare their data with the model's answer.

The seven-tool catalog includes four resource reads, a telemetry read,
`camera-pan`, and `recommendation-publish`. The host and sidecar reject disabled
actions; enabling them does not grant arbitrary topics, camera addresses, or
shell access. Resource queries remain read-only.

The optional [camera tutorial](docs/camera-actions.md) adds a software camera,
an AIO ONVIF connector template if one is needed, and a registered Device and
PTZ control Asset. No physical camera is required for that tutorial. There is
no web chat interface, continuous monitoring, historical store, model training,
automatic alerting, or recommendation-execution workflow.

## Architecture

![Custom MCP assistant with Foundry Local, MQTT observations, optional camera control, and approval-gated publishing.](media/architecture.svg)

Dashed outlines mark optional integrations. Observation producers and recommendation
consumers are deployed separately; the camera simulator is not automatically
connected to the observation pipeline.

| Component | Role in the scenario | Deployment |
| --- | --- | --- |
| Operator CLI | Sends questions/tool requests and explicitly approves or denies pending recommendations. | Runs on your workstation using authenticated `kubectl exec`; no public chat endpoint. |
| Assistant agent | Checks model-selected calls, collects evidence, and holds recommendations for approval. | `edge-assistant` Deployment. |
| Resource MCP service | Reads sanitized Asset and Device resources through the Kubernetes API. | Separate `edge-resource-mcp` Deployment with namespace-scoped read permissions. |
| MQTT MCP service | Samples JSON topics; optionally performs correlated camera RPC and acknowledged recommendation publication. | Sidecar in the assistant Pod; accessible only on Pod loopback. |
| Foundry Local text model | Selects tools and generates an answer using their results. | Dedicated generative `ModelDeployment` managed by the existing Foundry operator. |
| AIO broker and observation producer | Supply the messages to interpret. | Existing broker; companion predictive-inference pipeline or another separately deployed producer. |
| ONVIF connector and simulator, optional | Translate managed-action MQTT requests to ONVIF SOAP; the simulator changes its image viewport and PTZ state. | Native connector managed by AIO; sample-owned simulator Deployment and Service. |

### Request and data flow

1. You run `manage.py ask` from your workstation. The helper uses the explicit
   Kubernetes context in your configuration to send the question to the agent.
2. The agent sends the question and available tool definitions to Foundry Local.
   The model requests a resource read or a telemetry sample.
3. The selected MCP service reads the real data: the resource service queries
   AIO resources, or the MQTT service subscribes to the approved topics.
4. The agent returns the tool result to the text model, which generates its
   answer. Additional permitted reads can occur before the answer is returned.
5. The CLI prints both the answer and `toolActivity`, containing the actual
   arguments, resources, and messages used for that question.

Remote service connections use TLS and projected service-account tokens.
Resource permissions and broker authorization limit the data the tools can
read. Model output is not an authorization boundary.

The sample's Kubernetes manifests create the assistant workloads, identities,
and text-model request. They do not install AIO or Foundry Local, and do not
deploy or change the camera pipeline. See
[architecture and contracts](docs/architecture.md) for detailed permissions,
data formats, and component boundaries.

For an enabled camera action, the MQTT sidecar sends `ContinuousMove`, then
`Stop`, then `GetStatus` through the broker to the AIO ONVIF connector. Each
response must match its request's MQTT correlation data. A successful result
requires a confirmed stop and `IDLE` pan state.

For a recommendation, the question ends with `approval_required`; nothing is
published yet. A separate `manage.py approve` command consumes that approval
and publishes the reviewed payload. A denial, expired approval, or disabled
publisher sends no recommendation. The text model cannot approve its own request.

## Prerequisites

| Requirement | Expected capability |
| --- | --- |
| Development machine | Linux or WSL, Python 3.10+, Docker with Linux/amd64 image builds, and `kubectl`. |
| AIO installation | A working TLS MQTT listener supporting MQTT 5 `K8S-SAT` with audience `aio-internal`, plus namespaced Asset and Device CRDs under `namespaces.deviceregistry.microsoft.com/v1`. Register equipment before running the resource examples. |
| Foundry Local operator | `foundrylocal.azure.com/v1` `ModelDeployment`, internal HTTPS endpoints, SAT authorization, and the generative `onnx-genai` runtime for the selected compute. |
| Model catalog | Access to `qwen3.5-2b-text-generic-cpu:1`, the CPU text model used by the example configuration, and acceptance of its terms. The sample does not redistribute model weights. |
| TLS and networking | cert-manager with `cert-manager.io/v1` Issuer/Certificate support; accessible public broker and Foundry CA bundles; standard `cluster.local` DNS; a CNI enforcing NetworkPolicy. |
| Permissions | An installer able to create the listed sample resources and cross-namespace RBAC bindings; a platform owner to authorize MQTT subscriptions. |
| Container registry | A registry you can push to, and pull access for the sample namespace. |
| Observation producer | Required for MQTT questions: a running publisher of JSON objects on the selected topics. The companion person-detection pipeline is one supported input scenario. |

The default CPU model requests **4 CPUs and 4 GiB**, with limits of 8 CPUs and 8 GiB,
in addition to AIO and the assistant services. A GPU is **not required** for this
configuration. The selected node must have at least four allocatable CPUs
available; a four-vCPU VM normally has less after platform reservations.
Initial model download and CPU generation can take time. The helper does not
provision nodes or install platform components.

The installer needs broader permissions than an operator. An operator needs
access to get the sample Deployment, find its Pods, and create `pods/exec` in the
sample namespace. Exec is privileged container access, not an end-user chat
authorization mechanism. Do not grant it to untrusted users.

For platform setup and connecting existing resources, see
[connect the actual components](docs/operations.md#connect-the-actual-components).

## Build and test locally

From the repository root:

```bash
cd samples/aio-mcp-ai-assistant
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'

python -m pytest
ruff check src tests manage.py
ruff format --check src tests manage.py
```

The local tests use [mocks and fixtures](#real-components-mocks-and-replay-inputs);
they do not contact a cluster, subscribe to MQTT, or run the text model.
Continue with deployment to exercise the real integrations.

## Configure the instance

```bash
cp config.example.json config.json
```

Edit `config.json` before running the next commands. Replace every
`REPLACE_WITH_` value:

| Setting | How to choose it |
| --- | --- |
| `kubeContext` | An explicit context from `kubectl config get-contexts`. Helpers never switch the global context. |
| `namespace` | A new, dedicated namespace. The helper creates it and refuses to adopt unrelated existing resources. |
| `aioNamespace` | The namespace containing the AIO Asset/Device resources and broker CA ConfigMap. |
| `image` | Your registry/repository and a new explicit version tag. `latest` and unqualified image names are rejected. |
| `imagePullSecret` | An existing or planned registry pull secret in the sample namespace. Use `""` only when no secret is needed. |
| `broker` | The existing TLS listener host/port, CA ConfigMap name, and its PEM data key. Confirm the key: some installations use `trust-bundle.pem`, not `ca.crt`. |
| `foundry.namespace` | The existing Foundry operator/model namespace. |
| `foundry.deploymentName` | A new, dedicated model name; the helper will not overwrite an unrelated deployment. |
| `foundry.catalogName` / `catalogVersion` | The model's installed catalog name and version. Keep the example's Qwen CPU entry for the documented CPU configuration. |
| `foundry.assetId` | Required by Foundry 2.x: the catalog's exact versioned `azureml://registries/.../models/.../versions/...` ID, matching `catalogName` and `catalogVersion`. Omit only for older operators that accept `model.catalog`. |
| `foundry.compute` | `cpu` by default; `gpu` requires a compatible GPU model, provisioned GPU capacity, and `nodePool`. |
| `foundry.nodePool` | Optional existing AKS node-pool name; required for GPU. Use it to place the model on dedicated capacity. It does not create or modify the pool. |
| `foundry.tokenAudience` | The audience accepted by your installed Foundry gateway. Obtain it from the platform owner; do not guess or change the shared operator to match this sample. |
| `foundry.caConfigMap` / `caKey` | The public CA bundle for the model's internal HTTPS endpoint, in the configured Foundry namespace. |
| `sources` | One to eight distinct, exact JSON topics. Each has a `stage`, optional `machineId`, and meaningful `description`. Stage/machine bindings must be unique; wildcards are not allowed. |
| `camera` | Disabled by default. After [camera setup](docs/camera-actions.md), set `enabled: true`, the control `assetName`, and the discovered `profileToken`. |
| `recommendations` | Disabled by default. Set `enabled: true` and a dedicated exact `topic` only when an operator and intended consumer are ready. See [recommendation publishing](#review-and-publish-a-recommendation). |
| `simulator` | Omit for read-only use or real equipment. For the camera tutorial, add an `image` with your explicitly versioned simulator image. |

### Select the text model

The example selects `qwen3.5-2b-text-generic-cpu`, version `1`, with `compute`
set to `cpu`. For Foundry 2.x, add the following property **inside the existing
`foundry` object**, after confirming the entry in your installed catalog:

```json
{
  "assetId": "azureml://registries/azureml/models/qwen3.5-2b-text-generic-cpu/versions/1"
}
```

Use the gateway's actual token audience and public CA bundle. Do not change
shared platform authentication settings to match an example value.
GPU configuration is optional and requires a matching GPU catalog variant,
an existing GPU node pool, and installed drivers; see
[model integration](docs/operations.md#connect-the-agent-to-a-real-foundry-model).

### Connect the observation producer

For camera observations, deploy the companion
[person-detection pipeline](../edge-predictive-inference/README.md#deployment-and-operations)
with an authorized RTSP camera. Use its
[result reader](../edge-predictive-inference/README.md#run-and-observe-the-pipeline)
to confirm that it publishes observations before asking the assistant about them.

The default `sources` configuration connects these topics:

| Configuration label | `stage` | `machineId` | MQTT topic |
| --- | --- | --- | --- |
| `person-detections` | `inference` | `person` | `edge/predictive-inference/person/results` |
| `person-errors` | `errors` | `person` | `edge/predictive-inference/person/errors` |

If you changed the producer's topic prefix, update both topics. The tool uses
`stage` and `machine_id` to select these bindings; the configuration property is
spelled `machineId`. Configuration labels such as `person-detections` are not
tool arguments.

For another producer, use its exact JSON topics and describe what each payload
means in `description`. Do not select JPEGs, raw tensors, or sensitive telemetry:
selected payloads are sent to the text model and returned to the caller.
Resource reads also require care: sensitive-key redaction is not a complete
secret filter. Use secret references rather than credentials in resource text.

If you are starting with resource questions only, the producer can remain
undeployed. Leave valid source settings in the configuration, but do not
interpret an empty observation topic as a working pipeline.

## Deploy the scenario

Run the following steps in order from the sample directory with `.venv`
active and the populated `config.json` available. All cluster commands use
`kubeContext`; the helper does not change your global Kubernetes context.

### Build and publish the image

```bash
python manage.py render config.json
python manage.py build config.json
```

`render` validates configuration and writes reviewable YAML plus a broker rule
fragment under `.generated/`, without contacting the cluster. `build` creates
the Linux/amd64 container image identified by `image`. The same image runs the
agent, resource MCP service, and MQTT MCP sidecar.

Authenticate Docker to your registry using your organization's approved flow,
then publish:

```bash
python manage.py push config.json
```

Keep `config.json`, generated files, and credentials out of commits. The sample
ignores local configuration and build output.

### Prepare identities and TLS

Review the generated manifests, then prepare the sample namespace and access:

```bash
python manage.py prepare config.json
```

This checks the required platform namespaces and CRDs, validates the configured
CA bundles, and creates the dedicated namespace, two service accounts, scoped
RBAC, resource-MCP certificates, and a public trust ConfigMap. It waits for the
resource-MCP TLS certificate. It never copies platform private keys or registry
credentials.

If using a private image, now have the registry/cluster owner provision the
configured `imagePullSecret` in this new namespace. It must be a
`kubernetes.io/dockerconfigjson` secret with pull access to this image. The
helper does not create, display, or manage registry credentials.

### Authorize observation subscriptions

Have the broker owner review `.generated/broker-rule.json` and merge that rule
into the authorization policy attached to the configured listener, using the
platform's supported management path. Preserve the existing policy and other
clients' permissions.

With the default configuration, the rule grants **Connect and Subscribe only**.
Enabling actions adds only their exact Publish topics and the camera response
subscription; it never adds a wildcard grant. It matches the verified SAT
attribute created by this service-account
annotation:

```text
aio-broker-auth/edge-assistant: <sample-namespace>
```

It does not authorize by an arbitrary MQTT client ID or username. Authorization
policies are allow-only; the broker owner must also ensure no other matching
rule gives this identity broader access. Restrict who can assign these
service-account attributes.

The helper deliberately does not install a replacement broker policy, change
the listener, or alter default authentication. Follow
[Configure MQTT broker authorization](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-authorization#authorize-clients-that-use-kubernetes-service-account-tokens).

If a new restricted port is needed, have the broker owner add it to the existing
ClusterIP listener rather than creating a second ClusterIP listener. Preserve
other clients' settings. Authorization on one port does not restrict the same
identity on other reachable ports.

### Deploy the model and workloads

```bash
python manage.py model config.json
python manage.py status config.json
```

The model step requests a separate Qwen deployment, authorized only for the
sample agent service account. It does not reuse or replace the producer's
YOLOX model. Initial model download can take several minutes. Inspect `status`
and the [model logs](docs/operations.md#inspect-logs-and-events) to confirm the
requested model is serving before continuing.

Deploy the assistant and MCP services:

```bash
python manage.py workloads config.json
python manage.py check config.json
```

The workloads step creates the two Deployments and internal resource MCP
Service, and waits for rollout.

`check` verifies MCP discovery/authentication and the model endpoint lookup. It
should report `status: "ready"` and all seven tools, including disabled actions. Its
`modelInferenceVerified` and `mqttSubscriptionVerified` fields remain `false`
because this command does **not** run inference or sample messages. Use the
following examples to exercise those paths.

Deployment is staged, not transactional. A failed step leaves completed sample
resources in place for inspection. Correct the reported problem and rerun that
step; do not remove shared platform resources.

## Run and observe

### Inspect configured equipment

Start with direct resource reads. These call the resource MCP service without
using the language model:

```bash
python manage.py tool config.json list_assets '{"limit":5}'
python manage.py tool config.json list_devices '{"limit":5}'
```

List responses contain `items`, `count`, and `truncated`; `truncated: true`
means the returned list is incomplete. Use names from those results to retrieve
individual resources. The following commands use the
companion sample's default Asset and Device names; replace them if yours differ:

```bash
python manage.py tool config.json get_asset '{"name":"edge-person-camera"}'
python manage.py tool config.json get_device '{"name":"edge-person-camera"}'
```

The returned `item` contains the resource's metadata and redacted configuration.
Check the Asset's `spec.deviceRef` against the Device you retrieved.

Now ask the assistant to interpret the configuration:

```bash
python manage.py ask config.json \
  "List up to five configured assets and identify their device references."
```

The answer should identify resources actually returned by its tool calls.
Configuration, including an `enabled` flag, does not establish device health.

### Read and explain a person-detection observation

With the producer running, request one message from the results topic:

```bash
python manage.py tool config.json plant-telemetry \
  '{"stage":"inference","machine_id":"person","max_messages":1,"timeout_ms":5000}'
```

This subscribes for up to five seconds and returns the payload with its receipt
time. It does not ask the model to interpret it. A nonempty result should
contain the producer's `frameId`, `personCount`, and other observation fields.

Ask the assistant to read and explain a new observation:

```bash
python manage.py ask config.json \
  "Use plant-telemetry with stage inference, machine_id person, max_messages 1, and timeout_ms 5000. Report the frameId and personCount from the message."
```

Compare the answer with **this question's `toolActivity`**, not the earlier
direct read: each call opens a separate sampling window. Subscriptions can
receive retained messages, so inspect producer timestamps as well as receipt
times. The companion producer normally samples every five seconds; a
five-second window may return fewer messages than requested.

### Inspect the error topic

```bash
python manage.py tool config.json plant-telemetry \
  '{"stage":"errors","machine_id":"person","max_messages":1,"timeout_ms":5000}'

python manage.py ask config.json \
  "Use plant-telemetry with stage errors, machine_id person, max_messages 1, and timeout_ms 5000. Report observed failures and distinguish an empty window from a healthy pipeline."
```

An empty result means no messages were received in that window. It does not
prove that the pipeline is healthy or that no people were detected. The
companion pipeline's error topic does not cover every processing failure.

Each `ask` command starts an independent question, not a shared chat session.
Only one question runs at a time, with a five-minute deadline. Use direct tools
when you need the exact resource or observation values without model
interpretation.

### Pan the simulated camera

Complete the [camera deployment tutorial](docs/camera-actions.md) first. It
includes the simulator build, native ONVIF connector, Device/control Asset,
exact-topic authorization, and real-hardware replacement steps.

Call the action directly before testing model-selected movement:

```bash
python manage.py tool config.json camera-pan \
  '{"direction":"right","duration_seconds":2}'

python manage.py ask config.json \
  "Pan the configured simulated camera left for one second, then report whether it stopped and its final pan position."
```

The direct result must contain `moved: true`, `stopConfirmed: true`,
`moveStatus: "IDLE"`, and numeric `finalPan`. The model's answer must agree with
its own action result. Movement is limited to left/right at speed 0.35 for
1-6 seconds, with a default of two seconds.

This tests real MQTT and ONVIF transport against **simulated movement**.
It does not qualify a physical camera. If a model answer fails after movement,
inspect the tool trace and device state before retrying; another question can
cause another movement.

### Review and publish a recommendation

Set `recommendations.enabled` to `true` and choose a dedicated exact MQTT topic.
Keep validation messages separate from operational recommendations. Run
`manage.py render`, have the broker owner merge the updated rule, and run
`manage.py workloads` to deploy the configuration.

Start your authorized MQTT consumer on that topic **before approval**.
Give that consumer its own identity and an exact Subscribe grant; the assistant
does not deploy a downstream notification or action-execution service.

This example deliberately contains synthetic evidence. Replace it with actual
verified evidence for operational use:

```bash
python manage.py tool config.json recommendation-publish \
  '{"idempotency_key":"example-camera-review-001","recommendation":{"summary":"Review the simulated camera configuration.","severity":"LOW","actions":["Have an operator inspect the camera configuration."],"evidence":["Synthetic tutorial example; no real incident was observed."]}}'
```

The response contains `status: "approval_required"`, `published: false`, and
`approval` with the exact proposed arguments, an `id`, and `expiresAt`.
Review the whole payload, not just its summary. Within five minutes, choose
**one** of these commands, using the ID from your response:

```bash
python manage.py deny config.json APPROVAL_ID
# Or, after review:
python manage.py approve config.json APPROVAL_ID
```

A denial publishes nothing. Approval publishes once through the MQTT sidecar
using QoS 1, without retention, and returns the broker-acknowledged result.
The consumer receives an object containing `idempotencyKey` and
`recommendation`. Verify both against the reviewed request.
`published: true` confirms broker acceptance, not delivery to every consumer,
an alert being sent, or execution of the suggested actions.

To let the model propose the request instead:

> [!IMPORTANT]
> The configured CPU model has **not passed this recommendation-proposal
> flow** in the recorded checks: it returned invalid arguments or no proposal.
> The direct approval-and-delivery workflow above is independently validated.

```bash
python manage.py ask config.json \
  "Read up to two configured assets, then prepare a LOW-severity recommendation for an operator to review their configuration. Cite only the resources you actually read. Request approval; do not claim that anything has been published."
```

Inspect the returned tool evidence and proposal before approving. A normal
chat answer is not an approval request; require `approval_required` and a real
approval ID. There is no model-facing approval tool, and the direct
`recommendation-publish` command cannot bypass this step.

Approvals are single-use and expire after 300 seconds. Pending approvals and
the sidecar's successful-key ledger are in memory and disappear on restart.
Reusing a successful key with the same payload reports `duplicate: true`;
reusing it with different content fails. This is not durable exactly-once
delivery: consumers should also deduplicate `idempotencyKey`, and ambiguous
transport failures require checking the consumer before requesting a retry.

### Read the result

The following is an **abbreviated, illustrative response**, not a recorded
observation or a guaranteed model answer:

```json
{
  "status": "completed",
  "model": "qwen3.5-2b-text-generic-cpu:1",
  "answer": "The detector reports one person in frame example-frame-001. This is a result for one processed image, not a count of unique people over time.",
  "toolActivity": [
    {
      "tool": "plant-telemetry",
      "source": "mqtt",
      "arguments": {
        "stage": "inference",
        "machine_id": "person",
        "max_messages": 1,
        "timeout_ms": 5000
      },
      "result": {
        "topicFilter": "edge/predictive-inference/person/results",
        "messages": [
          {
            "topic": "edge/predictive-inference/person/results",
            "receivedAt": "2026-11-03T10:00:00+00:00",
            "payload": {
              "status": "ok",
              "frameId": "example-frame-001",
              "personCount": 1
            }
          }
        ],
        "count": 1,
        "timedOut": false
      }
    }
  ]
}
```

| Field | How to use it |
| --- | --- |
| `answer` | Model-generated explanation. Compare it with the retrieved data; it can omit details or make mistakes. |
| `toolActivity` | Actual executed tool calls and results. Use the resource names, topics, frame IDs, and payloads here to verify the answer. |
| `status: "completed"` | The request completed, not a guarantee of factual correctness. |
| `count` in an MQTT result | Number of messages received, not the number of people. Read `payload.personCount` for a frame's detection count. |
| `timedOut` | The window ended before the requested message count was reached. Partial results can still be present. |
| `receivedAt` | Local message receipt time, not camera capture time. Producer processing timestamps also do not necessarily represent capture time. |

The complete response also includes a request ID, timing, and model-completion
diagnostics for [troubleshooting](docs/operations.md#inspect-logs-and-events).

## Validate the integrations

Use these checks to establish what is working in your environment:

| Check | Expected outcome |
| --- | --- |
| `manage.py check` | Ready agent, discoverable tool catalogs, and a resolvable model endpoint. |
| Direct resource reads | Returned resources match the AIO configuration; sensitive fields are redacted. |
| Direct observation read with a running producer | Payloads match the producer's output, including frame IDs, counts, and timestamps. |
| Resource and observation questions | Actual tool calls are present, and the answer agrees with those exact results and includes the requested details. |
| Quiet error topic | An empty/time-out result, without a claim that the pipeline is healthy. |
| Invalid requests | A nonexistent resource, unconfigured source, or unsupported write tool fails explicitly. |
| Optional camera action | Correlated command responses, changed simulator position, explicit Stop, and final `IDLE`; no physical-motion claim. |
| Optional recommendation | No message before approval or after denial; approved payload observed independently on the configured topic. A reused approval is rejected. |

For example, this command must fail rather than subscribe to an arbitrary topic:

```bash
python manage.py tool config.json plant-telemetry '{"stage":"not-configured"}'
```

If direct tools work but a question fails or misinterprets data, investigate
the model path separately. Do not count readiness, an empty observation window,
or a successful HTTP response as an end-to-end result. See the
[operations guide](docs/operations.md) for logs and troubleshooting.

### Real components, mocks, and replay inputs

**The deployed assistant has no mock MCP or model mode.** It calls the real
Kubernetes API, MQTT broker, and configured Foundry model. The optional camera
is explicitly a simulator; local tests and external test producers are also
identified below:

| Location | Mocked or simulated input | How to exercise the real integration |
| --- | --- | --- |
| [`test_foundry.py`](tests/test_foundry.py), [`test_runtime.py`](tests/test_runtime.py), [`test_server.py`](tests/test_server.py) | Model streams, answers, and selected HTTP/tool backends. | Deploy the model and run `manage.py ask`; inspect actual tool activity and the answer. |
| [`test_resources.py`](tests/test_resources.py), [`test_mcp.py`](tests/test_mcp.py) | Resource fixtures, Kubernetes/TokenReview responses, and in-process MCP backends. | Register real equipment, then compare direct resource-tool results with AIO. |
| [`test_mqtt.py`](tests/test_mqtt.py) | A replaced MQTT client supplies messages, camera replies, and publication acknowledgements. | Use the real broker, ONVIF connector, and an independent recommendation subscriber. |
| [`test_deployment.py`](tests/test_deployment.py) | Cluster commands are replaced where deployment behavior is exercised. | Follow the deployment steps and inspect the created resources and rollouts. |
| README response examples | Illustrative JSON, not recorded observations. | Inspect the JSON returned by your own `tool` and `ask` commands. |
| [`simulator/`](simulator/) | A generated calibration panorama and software PTZ state stand in for a camera and physical motion. | Register an authorized ONVIF camera and its real profile using the [hardware replacement steps](docs/camera-actions.md#use-an-actual-onvif-camera). |
| Optional camera replay or synthetic publisher | Recorded camera content or generated JSON, respectively. Neither is supplied automatically by this assistant. | Connect an authorized physical camera and the actual pipeline as described in [producer integration](docs/operations.md#replace-synthetic-telemetry-or-camera-replay). |

Keep synthetic telemetry on separate validation topics and label it in both
payloads and source descriptions. A synthetic publisher bypasses the camera
and vision pipeline; a replay does not establish live physical-camera behavior.
Stop test publishers before validating the real producer.

## Limitations

The text model can omit requested details or misinterpret evidence. A known
limitation is that an answer can report correct person counts but omit the
requested frame IDs. Use `toolActivity` or direct tool reads when exact fields
are required. Model-selected camera movement passed against the simulator, but
model-generated recommendation proposals did not. Direct approval and MQTT
delivery passed independently. Model-assisted validation therefore remains
partial; recorded checks used simulated hardware and synthetic test inputs,
not a physical camera.
See [validation results and known issues](docs/operations.md#observed-model-limitations).

Do not treat the assistant as a health monitor, occupancy counter, or safety
decision system. Observations are bounded samples, not history; retained
messages can be stale. Counts are per frame and must not be summed as unique
people. Empty reads do not prove an empty scene or a healthy pipeline.

Validate authorization and network isolation in your deployment. The CNI must
enforce NetworkPolicy, and broker restrictions must cover all listener ports
reachable by the identity. Redaction and prompts do not replace access controls.

## Stop and clean up

Stop sending questions, then remove only this instance's explicitly named,
ownership-checked resources:

```bash
python manage.py cleanup config.json --yes
```

This removes the assistant workloads, dedicated Qwen `ModelDeployment`, sample
RBAC, resource-MCP certificates/secrets, and sample ConfigMaps/service accounts.
When `simulator` remains configured, it also removes the owned simulator
workload and its two credential Secrets. First remove the simulator's Azure
Device/control Asset using the [camera cleanup steps](docs/camera-actions.md#clean-up).
It retains the namespace, registry credentials/artifacts, platform installations,
and all producer resources. Broker authorization is externally managed: have its
owner remove only the sample's rule and review any cached authorization.
Separately provisioned node pools and broker ports are also retained; coordinate
their removal with the platform owner if no longer needed.

Keep the original configuration for cleanup. Changing namespace/model names
does not migrate or delete the resources created with the previous values.

## Source layout

| Path | Purpose |
| --- | --- |
| [`src/aio_mcp_ai_assistant/`](src/aio_mcp_ai_assistant/) | Agent, actual Foundry/MCP/MQTT clients, resource reader, and bounded tool contracts. |
| [`config.example.json`](config.example.json) | Deployment and runtime settings without credentials. |
| [`manage.py`](manage.py) | Explicit-context build, render, staged deployment, operator access, and cleanup. |
| [`kubernetes/`](kubernetes/) | Reviewable manifests for application ownership, identities, TLS, and the model. |
| [`simulator/`](simulator/) | Optional ONVIF/RTSP software camera with an explicitly synthetic scene. |
| [`bicep/`](bicep/) | Optional native ONVIF connector template and camera Device/control Asset. |
| [`onvif-connector-compat/`](onvif-connector-compat/) | Optional numeric-user packaging fix; the official native connector filesystem is unchanged. |
| [`tests/`](tests/) | Focused contract, failure, protocol, and deployment tests. |
| [`docs/architecture.md`](docs/architecture.md) | Data, authentication, and model/tool-loop contracts. |
| [`docs/camera-actions.md`](docs/camera-actions.md) | Deploy and exercise the simulated camera; replace it with authorized real hardware. |
| [`docs/operations.md`](docs/operations.md) | Platform integration, troubleshooting, validation results, updates, and cleanup. |
