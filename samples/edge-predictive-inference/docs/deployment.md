# Deploy and inspect the person-detection scenario

This guide covers initial deployment of the
[person-detection scenario](../README.md), from artifact preparation to observing
MQTT results and retrieving the associated model input and output files.
The deployment uses one camera, one model, and one data flow graph.

Review the [component compatibility requirements](architecture.md#compatibility)
before deploying. The camera and data flow are created disabled and enabled only
after their dependencies are ready.

## Prerequisites

The sample requires an existing compatible preview environment. It does not
install Azure Arc, Azure IoT Operations, Foundry Local, or a storage driver.
Foundry Local here is the Kubernetes predictive-model operator, not the desktop
application.

| Requirement | Details |
| --- | --- |
| Workstation | Linux or WSL, Bash, Python 3.10+, Rustup, Azure CLI with Bicep, `kubectl`, `jq`, and ORAS 1.2+. The pinned Rust toolchain is installed by Rustup when building. |
| AIO instance | AIO Apps support, graph file stores, and a compatible installed media connector. Exactly one ConnectorTemplate must match `Microsoft.Media`. |
| Model hosting | Foundry Local Kubernetes operator with predictive ONNX CPU hosting, HTTPS, and SAT authentication. |
| Azure resources | AIO instance, custom location, and Azure Device Registry (ADR) namespace in the configured resource group. Supply the ADR namespace's actual Azure region. |
| Authorization | Permission to deploy the sample's ARM/Kubernetes resources; an explicit subscription and Kubernetes context. |
| Camera | An authorized RTSP/RTSPS stream reachable by the media connector. Start with a modest resolution such as 640 x 360. Maximum accepted JPEG: 8 MiB and 4096 pixels per dimension. |
| Registry | A writable OCI registry and an existing AIO registry endpoint that can pull its graphs **and modules**. The `default` endpoint must resolve `mcr.microsoft.com`. |
| Storage | A dedicated 2 GiB ReadWriteMany (RWX) claim on a storage class supporting concurrent graph, connector, and reader access. See [storage permissions](operations.md#storage-and-retention). |

> [!IMPORTANT]
> **Use an instance without another inference connector for this initial
> deployment.** Do not install a second connector alongside an existing one.
> For a shared installation, its owner must merge the model, volume, and trust
> configuration into the existing managed connector and authorize its actual
> service account. Do not run the connector installation commands unchanged.

### Trust, credentials, and permissions

Foundry Local must accept the token audience **`aio-internal`**. The model
authorizes `azure-iot-operations/aioappcfg-edge-predictive-inference-sa`, the
service account generated for this AIO application configuration. Coordinate the
Foundry installation's audience with its owner; changing it can break other
clients. The sample does not change it.

Prepare these existing secrets through your approved secret-management process:

| Setting | Namespace | Contents |
| --- | --- | --- |
| `foundryTrustSecret` | `azure-iot-operations` | Foundry's CA certificate in `ca.crt`, as a Secret, not just a ConfigMap. |
| `modelRegistrySecret` | `foundryNamespace` | Registry credentials in `username` and `password` keys. These are not Docker pull-secret JSON. |
| Camera username/password references | Media connector's synchronized secret configuration | The example uses `camera-credentials/username` and `camera-credentials/password`. Configure actual synchronized references before enabling the camera. |

The example camera uses `UsernamePassword`. For an explicitly authorized,
isolated anonymous stream, set `cameraAuthentication` to `{"method":"Anonymous"}`.
Never put credentials in the RTSP URL or commit secrets in `config.json`.
Use RTSPS when supported; otherwise protect RTSP transport on the camera network.

Apply identity-scoped permissions through the existing broker authorization
policy:

| Identity | Required MQTT access |
| --- | --- |
| Media connector | Publish the configured `<topicPrefix>/frames`. |
| Data flow runtime | Subscribe to frames, publish results/errors, invoke this model's inference command, and receive SDK command replies. |
| Inference application | Serve this model's command topic and publish SDK replies. |
| `edge-predictive-reader` | Subscribe to frames, results, and errors. It needs no Kubernetes API role. |

The sample uses MQTT TLS and projected `K8S-SAT` authentication. It does not add
an anonymous listener, expose a broker port, replace authorization policies, or
grant unrestricted topic access.

## Prepare the model and build artifacts

Start from the repository root. Run subsequent commands in the sample directory
with its virtual environment active:

```bash
cd samples/edge-predictive-inference
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt -r models/requirements.txt
./build.sh
python models/prepare.py
```

`build.sh` builds two separate WASI components and a native validation helper.
`prepare.py` downloads the unmodified YOLOX-Nano export from the upstream
`0.1.1rc0` release and verifies its checksum, ONNX tensor contract, and
Apache-2.0 license. Model assets and generated outputs are ignored by Git.
Review [third-party notices](../THIRD-PARTY-NOTICES.md) before redistribution.

Optionally run local model inference with an authorized JPEG:

```bash
python models/verify.py --image /absolute/path/to/authorized-camera-image.jpg
```

This uses the **same Rust preprocessing and postprocessing** as the WASM components
and ONNX Runtime CPU inference. It saves the tensor request, raw tensor response,
frame context, and final observation under `.build/local-inference`.
It does not exercise the media connector, MQTT, the native connector, or Foundry
Local. Those integrations must be verified on the target cluster.

## Configure the deployment

```bash
cp config.example.json config.json
# Edit config.json for your environment.
python render.py config.json
```

Replace every `REPLACE_WITH_` value. Choose a **new camera/asset name** for this
sample and a dedicated data claim; do not reuse unrelated resources.
`registryEndpointName` is the AIO registry endpoint's **name**, while `registry`
is the registry's **host**.

`modelEndpoint` must be the actual HTTPS **base URL** of the new Foundry model.
The example uses the documented per-model Service on port 5000. If your operator
reports an internal gateway URL containing the model name, use that complete
base URL instead. Verify it after model deployment below. Do not append
`/v1/predict`; the connector does that.

The renderer validates configuration and creates `.generated/`:
ARM parameter files, Kubernetes manifests, and two custom graph artifacts.
The initial camera and data flow are **disabled**. Edit source configuration,
not generated files; subsequent commands render them again.

## Publish model and graph artifacts

Authenticate ORAS to your registry using your approved credential workflow, then:

```bash
./publish.sh config.json
```

This publishes five artifacts beneath
`<registry>/azure-samples/edge-predictive-inference`, using `artifactVersion`:

| Artifact | Contents |
| --- | --- |
| `preprocess` / `postprocess` | The two compiled WASM components. |
| `preprocess-graph` / `postprocess-graph` | Their graph definitions and configuration contracts. |
| `yolox-nano` | `model.onnx`, the upstream license, and checksum/tensor provenance. |

The built-in Microsoft inference graph and its module are pulled separately from
MCR through the `default` registry endpoint. This sample does not republish or
replace them. After changing code, run `build.sh` again before publishing; use a
new artifact version rather than overwriting a version used by running workloads.

## Prepare storage and deploy the model

```bash
./deploy.sh preflight config.json
./deploy.sh storage config.json
./deploy.sh model config.json
```

The first-install checks refuse an existing inference connector and conflicting
model/PVC ownership. Storage initialization creates only the sample's two
directories. A cleanup CronJob runs once per minute.

Wait for Foundry to load the model and report readiness. Inspect its actual
endpoint and your operator's status:

```bash
CONTEXT=$(jq -er '.kubeContext' config.json)
MODEL=$(jq -er '.modelName' config.json)
FOUNDRY=$(jq -er '.foundryNamespace' config.json)
kubectl --context "$CONTEXT" get modeldeployment "$MODEL" -n "$FOUNDRY" -o yaml
```

Confirm registry download, model readiness, HTTPS endpoint, CA trust, and token
audience. Update `modelEndpoint` in `config.json` if the reported base URL differs.
An accepted Kubernetes manifest alone is not evidence that the model is serving.

## Deploy the application and disabled pipeline

```bash
./deploy.sh definition config.json
./deploy.sh connector config.json
./deploy.sh camera config.json
./deploy.sh flow config.json
./deploy.sh reader config.json
./deploy.sh status config.json
```

The definition step waits for application metadata readiness before the
configuration is created. The connector uses the generated AIO Apps identity,
Foundry CA trust, one mRPC worker, and the shared claim. It serves the configured
model and persists responses to disk.

Verify that the connector is running, both graph file stores are present, the
graph artifacts resolve, the reader is ready, and the model is ready.
The first-install helper deliberately refuses to replace an already running
connector, including this sample's. For subsequent updates, follow
[managed updates](operations.md#managed-updates).

## Enable the pipeline and observe results

Enable the graph before the camera starts publishing:

```bash
./deploy.sh enable config.json
CONTEXT=$(jq -er '.kubeContext' config.json)
PREFIX=$(jq -er '.topicPrefix' config.json)
```

Read five results/errors through the authenticated reader:

```bash
kubectl --context "$CONTEXT" exec -n azure-iot-operations edge-predictive-reader -- \
  sh -ec 'exec mosquitto_sub -h aio-broker -p 18883 -V mqttv5 -q 1 \
    -t "$1/results" -t "$1/errors" -C 5 -W 90 -F "%t %p" \
    --cafile /var/run/certs/ca.crt \
    -D CONNECT authentication-method K8S-SAT \
    -D CONNECT authentication-data "$(cat /var/run/secrets/tokens/broker-sat)"' \
  sh "$PREFIX"
```

Successful messages contain the fields shown in the
[example observation](../README.md#example-observation). Counts, boxes, confidence,
and timing depend on the input. A zero-person result is valid only when inference
succeeds; missing results and error messages must not be interpreted as zero.

Check camera and model readiness, result freshness, and the referenced files
before treating the integration as operational. If messages do not arrive, use
[missing-result diagnostics](operations.md#inspect-readiness-and-missing-results).

## Inspect the model input and output

Capture one successful observation:

```bash
CONTEXT=$(jq -er '.kubeContext' config.json)
PREFIX=$(jq -er '.topicPrefix' config.json)
kubectl --context "$CONTEXT" exec -n azure-iot-operations edge-predictive-reader -- \
  sh -ec 'exec mosquitto_sub -h aio-broker -p 18883 -V mqttv5 -q 1 \
    -t "$1/results" -C 1 -W 60 -F "%p" \
    --cafile /var/run/certs/ca.crt \
    -D CONNECT authentication-method K8S-SAT \
    -D CONNECT authentication-data "$(cat /var/run/secrets/tokens/broker-sat)"' \
  sh "$PREFIX" > .build/observation.json

REQUEST=$(jq -er 'select(.status == "ok") | .files.request |
  select(test("^[0-9a-f-]{36}\\.json$"))' .build/observation.json) &&
RESPONSE=$(jq -er 'select(.status == "ok") | .files.response |
  select(test("^[A-Za-z0-9._-]{1,128}$") and . != "." and . != "..")' .build/observation.json) &&
kubectl --context "$CONTEXT" cp \
  "azure-iot-operations/edge-predictive-reader:/data/edge-predictive-inference/inputs/$REQUEST" \
  .build/request.json &&
kubectl --context "$CONTEXT" cp \
  "azure-iot-operations/edge-predictive-reader:/data/edge-predictive-inference/responses/$RESPONSE" \
  .build/response.json
```

Copy promptly: the cleanup job selects files with `find -mmin +5` once per minute.
This is short-lived scratch storage, not permanent evidence retention.

Inspect tensor shapes without printing hundreds of thousands of values:

```bash
python - <<'PY'
import json
import numpy as np
from pathlib import Path
request = np.asarray(json.loads(Path(".build/request.json").read_text()))
response = np.asarray(json.loads(Path(".build/response.json").read_text())["output_0"])
print("Request:", request.shape, "range:", request.min(), request.max())
print("Response:", response.shape)
PY
```

Expected shapes are `(1, 3, 416, 416)` and `(1, 3549, 85)`. The request is an
unnormalized BGR tensor with values in `[0,255]`, not JPEG bytes or a file-system
path. The response is the raw tensor, not the final detection list.

To inspect an incoming JPEG independently, subscribe to `<topicPrefix>/frames`
with `mosquitto_sub -C 1 -W 30 -N` and redirect its binary output to a `.jpg` file.
Do not use the JSON formatting option. Such a separately captured JPEG is
**not guaranteed to be the frame associated with an observation**.

## Stop processing

```bash
./deploy.sh disable config.json
```

This requests camera shutdown before disabling the graph. Confirm reconciliation
before deleting resources. The model, connector, reader, and cleanup job remain
deployed until explicitly removed.

See [operations and cleanup](operations.md) for missing-result diagnostics,
storage permissions, managed updates, and resource-specific removal commands.
The sample does not delete its PVC automatically.
