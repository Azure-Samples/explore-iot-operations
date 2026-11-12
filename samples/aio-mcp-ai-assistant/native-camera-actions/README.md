# Data flow graphs for camera control

This directory contains the WebAssembly (WASM) modules and graph definitions
used by three Azure IoT Operations (AIO) **data flow graphs for camera control**.
Each deployed `DataflowGraph` has an MQTT source, a custom WASM transform, and
an MQTT destination. These let the assistant use the **built-in MCP frontend
exclusively**, including for camera control. They are not custom MCP servers,
MQTT sidecars, or replacements for the connector for ONVIF.

`aio_mqtt_publish` cannot attach MQTT RPC properties. The custom WASM transform's
`wasm_graph_sdk` 1.7.4 command invoker adds the response topic, correlation data,
and command timeout, invokes the configured Asset's `PTZ` managed action,
and publishes the actual result for `aio_mq_messages` to sample.

Follow the complete [camera tutorial](../docs/camera-actions.md) for registry
access, Device/Asset registration, ARM deployment, and live qualification.

## Inputs and outputs

One data flow graph handles each of `GetStatus`, `ContinuousMove`, and `Stop`:

| Boundary | Contract |
| --- | --- |
| Input | Exact `<camera.topicPrefix>/requests/<Action>` topic. |
| ONVIF managed-action topic | `azure-iot-operations/asset-operations/<assetName>/PTZ/<Action>`. |
| Output | Exact `<camera.topicPrefix>/responses/<Action>` topic. |
| Module configuration | Required `asset_name` and `profile_token`; no caller-controlled managed-action destination. |

Illustrative request; replace timestamps and IDs with fresh values:

```json
{
  "requestId": "0123456789abcdef0123456789abcdef",
  "issuedAt": 1793898000,
  "action": "GetStatus",
  "payload": {"GetStatus": {"ProfileToken": "profile_high"}}
}
```

Request envelopes reject unknown fields and exceed neither 64 KiB nor the
configured action's age limit: five seconds for Move, ten for Stop/GetStatus,
with at most five seconds of future clock skew. Move accepts only horizontal
speed `-0.35` or `0.35` and canonical `PT1S` through `PT6S` duration. Stop
requires `PanTilt: true` and `Zoom: false`.

Replies contain `type: "camera-action-result"`, the original `requestId`,
`action`, and `issuedAt`, plus `assetName`, `profileToken`, `completedAt`,
`response`, and `error`. `response` preserves the ONVIF managed-action RPC object
unchanged; failure returns an explicit error rather than a synthetic camera state.
Undecodable requests cannot be correlated and fail the graph operation.

ONVIF managed-action RPC timeout/expiry is two seconds for Move/GetStatus and
eight seconds for Stop. The process-local FIFO ledger remembers 1024 request IDs, including
failed invocation attempts; it is not durable exactly-once execution. Requests
are not automatically retried. Separate graphs prevent a blocked Move operator
from serializing Stop but cannot guarantee broker/connector ordering.

## Build and publish

From the parent sample directory, with its Python environment active:

```bash
bash native-camera-actions/build.sh
bash native-camera-actions/publish.sh config.json
```

Build requires Rust/rustup and the declared `wasm32-wasip2` target. It runs
format checks, Rust unit tests, Clippy, and all three WASM builds. Unit tests
use synthetic envelopes; they do not contact an MQTT broker or camera.

Publication requires ORAS, approved registry authentication, and a populated
`cameraGraphs` configuration. It pushes three WASM modules and three graph
definition artifacts under `azure-samples/aio-mcp-ai-assistant/camera-actions`. The existing
AIO registry endpoint must independently have pull access to these paths.
Do not use mutable `latest` tags or commit registry credentials.

Deploy the GetStatus data flow graph first and run `manage.py camera-check`.
Enable the Move/Stop data flow graphs and `camera.enabled` only after harmless
status qualification, an authorized operator's review, and confirmation that no competing controller
owns the camera.
