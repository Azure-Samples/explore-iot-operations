# Add camera control through the AIO connector for ONVIF

This tutorial extends the [operations assistant](../README.md) with its
`camera-pan` tool. You will deploy the prebuilt camera simulator, connect it to the real
AIO connector for ONVIF, register a Device and a PTZ control Asset, and move its
viewport through correlated MQTT managed-action requests.

**What is simulated:** the camera, its calibration scene, and physical motion.
The scene is generated at image-build time and contains no real people or
equipment. The simulator implements ONVIF SOAP and H.264 RTSP; it is not a
scripted MCP response. The built-in MCP frontend/backend, MQTT broker, AIO connector, and
Device/Asset APIs are real. This tutorial does not deploy the separate media
or person-detection pipeline.

The assistant never opens a broker connection. Three AIO data flow graphs run
custom WASM transforms that bridge JSON publication/sampling to the MQTT RPC
properties required by ONVIF managed actions. Deploy and qualify the GetStatus
data flow graph before enabling movement.
Use the simulator and all six graph/module artifacts from the same
[coordinated release](../../../docs/edge-ai-samples-release.md) as the assistant.
The [2026-11-11 private qualification](../../../docs/edge-ai-samples-validation.md)
passed GetStatus and direct bounded pan with the official `1.6.5` connector.
Consult that record separately for model-selected behavior. Public GHCR
publication remains pending; the example tag is not an available release.

## Prerequisites

Complete the main sample's namespace, identities, image-pull access, model,
and workload deployment first. You also need:

- Azure CLI with Bicep support and permission to deploy resources into the
  existing AIO instance, Azure Device Registry (ADR) namespace, and custom location.
- An AIO installation supporting the supplied preview ARM APIs and the
  connector for ONVIF. The template pins connector and metadata version `1.6.5`,
  whose metadata requires AIO `1.3.38` or later.
- Device/Asset resource synchronization between Azure and the cluster,
  configured by the platform owner. See
  [configure the connector for ONVIF](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-onvif-connector).
- CPU capacity for the simulator (500m CPU/512 MiB requested, 2 CPU/1 GiB limit)
  and the connector for ONVIF. No GPU is required.
- Pull access to the published simulator and camera-control graph/module
  artifacts. Rust, Docker builds, and registry push access are only needed for
  [customization](#customize-the-camera-components).
- A compatible AIO WASM runtime (the graph definitions declare API 1.7.2/runtime 1.1.8)
  and an existing registry endpoint with pull access to all six artifacts.
- Platform approval for the frontend `Admin` role needed by
  `aio_mqtt_publish`, including for harmless GetStatus requests. Admin is
  broader than this application's tool/topic allowlist.

Use unused Device/Asset names. Do not overwrite registrations for real cameras.
If a suitable connector template for ONVIF already exists, reuse it rather than
creating a second template for the same endpoint type.

## 1. Select the published simulator image

From `samples/aio-mcp-ai-assistant`, with the main virtual environment active:

Add the following object to the existing `config.json`, substituting your
verified release version. Leave `camera.enabled` false while preparing the integration:

```json
{
  "simulator": {
    "image": "ghcr.io/azure-samples/explore-iot-operations/onvif-simulator:REPLACE_WITH_PUBLISHED_VERSION"
  }
}
```

This fragment is not a replacement for the complete configuration. The image
must use a valid lowercase registry/repository and a non-`latest` version tag.
Keep `imagePullSecret: ""` for public GHCR images. For a private mirror, the
Secret must cover **both** assistant and simulator repositories; access to one
does not authorize the other. The simulator uses Python 3.12 inside the image;
your workstation does not need to build it or change its Python version.

## 2. Deploy the software camera

```bash
python manage.py render config.json
python manage.py simulator config.json
```

The helper creates or reuses two ownership-checked credential Secrets: one in
the sample namespace for the simulator, and one in the AIO namespace for the
connector. The camera password and administrative token are randomly generated;
rerunning the command does not rotate them. The administrative token is not
copied into the AIO namespace. The helper never prints credential values.

These are **local evaluation Secrets**, not Key Vault-synchronized production
credentials. For real equipment, use the platform's
[secret management workflow](https://learn.microsoft.com/azure/iot-operations/secure-iot-ops/howto-manage-secrets).

The helper deploys a single `edge-assistant-camera` Pod and a ClusterIP Service,
and waits for readiness. There is no public load balancer. Its state uses
`emptyDir`; replacing the Pod resets the simulated position.

Load the nonsecret deployment values:

```bash
CONTEXT=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).kube_context)')
NAMESPACE=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).namespace)')
AIO_NAMESPACE=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).aio_namespace)')
CAMERA_ASSET=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).camera.asset_name)')
CAMERA_CREDENTIAL_SECRET=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).camera_secret)')

kubectl --context "$CONTEXT" -n "$NAMESPACE" get deployment,service edge-assistant-camera
```

The Service exposes ONVIF on port 2020 and RTSP on port 554. The default profiles
are `profile_high` and `profile_standard`; both share the same PTZ state.

## 3. Add the connector for ONVIF when needed

Set these values for your existing installation; do not use names from another
cluster. `ADR_LOCATION` is the ADR namespace's Azure region:

```bash
SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
RESOURCE_GROUP="YOUR_RESOURCE_GROUP"
AIO_INSTANCE="YOUR_AIO_INSTANCE"
CUSTOM_LOCATION="YOUR_CUSTOM_LOCATION"
ADR_NAMESPACE="YOUR_ADR_NAMESPACE"
ADR_LOCATION="YOUR_ADR_REGION"
CONNECTOR_TEMPLATE="edge-assistant-onvif"
CAMERA_DEVICE="edge-assistant-camera"

kubectl --context "$CONTEXT" -n "$AIO_NAMESPACE" get connectortemplates
```

Have the platform owner inspect existing templates for `Microsoft.Onvif`.
**Skip the following deployment if you will reuse an existing compatible
template.** Otherwise, validate and deploy the supplied connector template:

```bash
az deployment group validate \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-onvif \
  --template-file bicep/onvif-connector.bicep \
  --parameters aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    connectorTemplateName="$CONNECTOR_TEMPLATE"

az deployment group create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-onvif \
  --template-file bicep/onvif-connector.bicep \
  --parameters aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    connectorTemplateName="$CONNECTOR_TEMPLATE"
```

The connector for ONVIF image comes from Microsoft Container Registry. ARM and
AIO own its runtime reconciliation; the assistant does not directly create a
connector Pod. An allocated connector may appear only after registering an
enabled ONVIF Device. No Event Grid or cloud managed-action gateway is needed
for this local broker-to-connector path.

### Numeric non-root image compatibility

The unmodified Microsoft `1.6.5` image declares numeric UID `65532` and passed
startup, Device/Asset discovery, action registration, and correlated GetStatus
in the [private qualification run](../../../docs/edge-ai-samples-validation.md).
No compatibility image or generated-workload patch was required.

The older `1.5.0` image declares its existing UID/GID 65532 account by the
name `nonroot`. An operator-generated Pod with `runAsNonRoot: true` and no
explicit numeric UID can therefore fail with:

```text
image has non-numeric user (nonroot), cannot verify user is non-root
```

The earlier custom-MCP camera integration used the included
[`onvif-connector-compat/Dockerfile`](../onvif-connector-compat/Dockerfile).
It pins the official `1.5.0` base digest and changes only `USER` to
`65532:65532`; the connector filesystem and entrypoint are unchanged.
This is a packaging workaround, **not a mocked or reimplemented connector**.
It does not qualify the unmodified image on affected installations.

The wrapper is historical development material, not a prerequisite for this
tutorial. Use the compatible official image. If another image/operator
combination cannot start, record a blocked prerequisite and resolve it with the
platform owner. Keep `runAsNonRoot` enabled; do not patch generated Pods or
disable admission controls.

## 4. Register the camera and its managed actions

The supplied template creates an enabled Device with endpoint `onvif`, plus
the Asset named by `camera.assetName`. Its `PTZ` management group exposes only
`ContinuousMove`, `Stop`, and `GetStatus`.

The endpoint below points exclusively to the sample's simulated camera:

```bash
CAMERA_ENDPOINT="http://edge-assistant-camera.${NAMESPACE}.svc.cluster.local:2020/onvif/device_service"

az deployment group validate \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera \
  --template-file bicep/camera.bicep \
  --parameters customLocationName="$CUSTOM_LOCATION" adrNamespaceName="$ADR_NAMESPACE" \
    adrNamespaceLocation="$ADR_LOCATION" sampleNamespace="$NAMESPACE" \
    cameraDeviceName="$CAMERA_DEVICE" cameraAssetName="$CAMERA_ASSET" \
    cameraEndpointUrl="$CAMERA_ENDPOINT" cameraCredentialSecretName="$CAMERA_CREDENTIAL_SECRET"

az deployment group create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera \
  --template-file bicep/camera.bicep \
  --parameters customLocationName="$CUSTOM_LOCATION" adrNamespaceName="$ADR_NAMESPACE" \
    adrNamespaceLocation="$ADR_LOCATION" sampleNamespace="$NAMESPACE" \
    cameraDeviceName="$CAMERA_DEVICE" cameraAssetName="$CAMERA_ASSET" \
    cameraEndpointUrl="$CAMERA_ENDPOINT" cameraCredentialSecretName="$CAMERA_CREDENTIAL_SECRET"

kubectl --context "$CONTEXT" -n "$AIO_NAMESPACE" get \
  devices.namespaces.deviceregistry.microsoft.com "$CAMERA_DEVICE" -o yaml
kubectl --context "$CONTEXT" -n "$AIO_NAMESPACE" get \
  assets.namespaces.deviceregistry.microsoft.com "$CAMERA_ASSET" -o yaml
kubectl --context "$CONTEXT" -n "$AIO_NAMESPACE" get connectors,pods
```

Wait for the Device and Asset to synchronize and the connector to report
successful allocation/configuration. Inspect connector logs if discovery or
authentication fails. An ARM deployment reporting `Succeeded` alone does not
establish that the connector reached the camera.

## 5. Deploy the camera-control data flow graphs

Extend `config.json` with the following objects, using your actual Asset,
release version, and dedicated AIO GHCR registry endpoint. Use a unique `topicPrefix` for
each instance and **leave movement disabled**:

```json
{
  "camera": {
    "enabled": false,
    "assetName": "edge-assistant-camera-onvif",
    "profileToken": "profile_high",
    "topicPrefix": "edge/assistant/camera"
  },
  "cameraGraphs": {
    "registry": "ghcr.io",
    "artifactRepository": "azure-samples/explore-iot-operations/aio-mcp-ai-assistant/camera-actions",
    "registryEndpointName": "YOUR_AIO_REGISTRY_ENDPOINT",
    "artifactVersion": "REPLACE_WITH_PUBLISHED_VERSION"
  }
}
```

Set `artifactVersion` to the same release as the assistant and simulator.
Render from the sample directory with its Python environment active:

```bash
python manage.py render config.json
```

This renders the graph parameters; it does not build or publish anything.
AIO pulls three graph definitions and their three matching WASM modules beneath
`ghcr.io/azure-samples/explore-iot-operations/aio-mcp-ai-assistant/camera-actions`.
See the [camera-control data flow graph contracts](../native-camera-actions/README.md).
The agent image-pull Secret does not grant AIO permission to pull graph artifacts;
the existing **AIO registry endpoint** must do that independently.
Follow the [registry setup](../../../docs/edge-ai-samples-release.md#2-configure-the-independent-registry-consumers)
and keep the platform's `default` MCR registry endpoint unchanged.

Rendering also creates `.generated/camera-actions.parameters.json`. The template
uses a dedicated data flow profile named `edge-camera-<sample namespace>` and
the existing `default` MQTT endpoint. Confirm that this is a new data flow
profile, or one created exclusively for this same sample instance; never overwrite another application's
data flow profile. Validate and deploy **GetStatus only**:

```bash
az deployment group validate \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera-actions \
  --template-file bicep/camera-actions.bicep \
  --parameters @.generated/camera-actions.parameters.json \
    aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    actions=get-status

az deployment group create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera-actions \
  --template-file bicep/camera-actions.bicep \
  --parameters @.generated/camera-actions.parameters.json \
    aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    actions=get-status
```

The three `DataflowGraph` resources are independent, not three serial nodes.
Each has an MQTT source, a custom WASM transform, and an MQTT destination.
They do not persist requests to disk and do not use file stores. The SDK command
invoker supplies MQTT correlation/response properties; its process-local
request-ID ledger is not durable exactly-once execution.

Have the platform owner review `.generated/mcp-access.json` and confirm:

- The agent's frontend roles include `Reader`, `DataReader`, and `Admin`.
- The backend can publish to `<topicPrefix>/requests/<Action>` and sample
  `<topicPrefix>/responses/<Action>` for the configured actions.
- The data flow graph and connector identities can exchange ONVIF managed-action
  requests/replies for the configured Asset. Their identities are separate
  from the agent's frontend identity.

The inventory is not a broker ACL. Do not give the application a direct broker
token or modify shared policies to hide an authorization failure.

Apply the role annotation and single-container workload, then request harmless
status through the complete built-in MCP/data flow graph/connector path:

```bash
python manage.py prepare config.json
python manage.py workloads config.json
python manage.py check config.json
python manage.py camera-check config.json
```

Require the actual correlated GetStatus result, `stopConfirmed: true`,
`moveStatus: "IDLE"`, and a finite normalized `finalPan`. Compare it with the
simulator or an independently authorized camera status read. Readiness or an
ARM deployment reporting success does not replace this check. Resolve schema,
role, registry, graph, clock, and camera errors before continuing.

After a graph update, an existing `Available` condition can precede completion
of the new graph/module downloads. The private run encountered an initial
GetStatus timeout during this transition; the check succeeded after the new
artifacts loaded. Confirm the selected artifact version in controller/runtime
logs and repeat only the harmless status check. Do not use movement or retry a
timed-out Move as a readiness probe.

## 6. Enable motion and run a direct action

Confirm that no other controller owns the camera. Validate and deploy the
Move and Stop data flow graphs alongside GetStatus:

```bash
az deployment group validate \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera-actions \
  --template-file bicep/camera-actions.bicep \
  --parameters @.generated/camera-actions.parameters.json \
    aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" actions=all

az deployment group create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-camera-actions \
  --template-file bicep/camera-actions.bicep \
  --parameters @.generated/camera-actions.parameters.json \
    aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" actions=all
```

Wait for all three data flow graphs to become operational in AIO. Set
`camera.enabled: true`, then update the agent:

```bash
python manage.py render config.json
python manage.py prepare config.json
python manage.py workloads config.json
python manage.py tool config.json camera-pan \
  '{"direction":"right","duration_seconds":1}'
```

The successful result has this shape; the position shown is **illustrative**:

```json
{
  "moved": true,
  "direction": "right",
  "speed": 0.35,
  "durationSeconds": 1,
  "stopConfirmed": true,
  "moveStatus": "IDLE",
  "finalPan": 0.12
}
```

The client begins sampling before publication, uses a fresh ID and issued
timestamp, and validates the graph's correlated ONVIF managed-action response.
The frontend has no subscription-ready acknowledgement, so missing replies can still time
out. `ContinuousMove` includes a device-side timeout; there is no automatic
retry of movement. An explicit Stop is attempted even after an uncertain Move,
followed by GetStatus. Uncertain delivery triggers an additional 12-second
fence and Stop/IDLE verification without turning failure into success.
Unconfirmed recovery blocks further movement in that process.

Inspect the simulator logs independently:

```bash
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs \
  deployment/edge-assistant-camera --tail=80
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs \
  deployment/edge-assistant -c agent --tail=80

python manage.py ask config.json \
  "Pan the configured simulated camera left for one second. Report the confirmed stopped state and final pan position."
```

Require an actual `camera-pan` entry in `toolActivity`, successful correlated
responses, and an answer consistent with them. A completed chat response alone
is insufficient. If movement completed but the final model answer failed,
inspect state before retrying to avoid repeating the movement.

## Use an actual ONVIF camera

Do not treat simulator success as hardware qualification. Obtain the camera
owner's authorization and check the permitted direction, speed, duration,
travel limits, and emergency-stop procedure before enabling movement.

1. Keep `camera.enabled: false` and do not deploy its Move data flow graph while preparing
   the real target. Register the authorized camera's actual ONVIF endpoint,
   using HTTPS and an appropriate trust bundle where supported.
2. Store real credentials in Key Vault and synchronize them through AIO. Set
   the Device's `usernameSecretName` and `passwordSecretName` to the actual
   synced-secret references. Do not reuse the simulator Secrets or put
   credentials in a URL.
3. Use ONVIF discovery to identify the actual media profile token and PTZ
   capabilities. The physical device must support the three managed actions,
   normalized horizontal velocity, a bounded `ContinuousMove` timeout, and
   `GetStatus` with an `IDLE` pan state and position. Do not assume its profile
   is named `profile_high`.
4. Create a separate control Asset using the verified Device/endpoint and
   the three managed actions. Set `camera.assetName` and `profileToken` to
   that target. Use new, instance-specific bridge topics and regenerate graph
   parameters. Omit `simulator` if no software camera is needed.
5. Deploy only the GetStatus data flow graph and qualify `camera-check` before enabling
   motion. In a controlled maintenance window, deploy all three data flow graphs, enable the
   camera setting, and test the smallest permitted direct movement
   before model-assisted use. A fixed speed of 0.35 and a one-second minimum
   are built into this sample; do not use it on hardware for which these
   bounds are unsuitable.

This sample is not a safety controller. Network loss can prevent Stop or its
confirmation; a timeout/error is not proof that physical motion stopped.
The independently configured device timeout and hardware safeguards remain
essential. A separate media/inference deployment is required to produce
observations from the real camera's stream.

## Customize the camera components

Skip this section when using the coordinated release. To change the simulator,
use Docker and publish to your own repository with a new explicit version:

```bash
SIMULATOR_IMAGE="YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.1"
docker build --target test --tag aio-onvif-simulator-test ./simulator
docker build --platform linux/amd64 --tag "$SIMULATOR_IMAGE" ./simulator
docker push "$SIMULATOR_IMAGE"
```

Update `simulator.image` and its pull access. The tests cover authentication
replay and device-side timeouts with protocol fixtures; they do not qualify a
physical camera. See the [simulator behavior](../simulator/README.md#authentication-and-movement-behavior).

For WASM changes, install Rust/rustup with the pinned toolchain and
`wasm32-wasip2` target, plus ORAS. Set `cameraGraphs.registry` and
`artifactRepository` to your own repository prefix and choose a new
`artifactVersion`. Authenticate ORAS using your approved process, then run:

```bash
bash native-camera-actions/build.sh
bash native-camera-actions/publish.sh config.json
```

The publisher uploads all three modules and all three graph definitions. It
refuses the official GHCR namespace, which is reserved for the coordinated
workflow. Update AIO registry pull access as needed and repeat GetStatus
qualification before enabling movement with the changed graphs.

## Clean up

Stop issuing actions, confirm the camera is IDLE, set `camera.enabled: false`,
and redeploy the agent. Remove the sample's camera-control data flow graphs before its
camera registration or simulator. Changing an incremental ARM deployment back
to `actions=get-status` **does not delete previously deployed Move/Stop graphs**.
Removing `cameraGraphs` from local configuration also does not delete them.

Derive the exact dedicated data flow profile and inspect its contents:

```bash
PROFILE=$(python -c 'from pathlib import Path; from aio_mcp_ai_assistant.config import load_settings; print(load_settings(Path("config.json")).camera_profile_name)')
AIO_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.IoTOperations/instances/${AIO_INSTANCE}"
PROFILE_ID="${AIO_ID}/dataflowProfiles/${PROFILE}"

az resource show --ids "$PROFILE_ID" --api-version 2026-11-01-preview
az rest --method get \
  --url "https://management.azure.com${PROFILE_ID}/dataflowGraphs?api-version=2026-11-01-preview"
```

Verify that this is the dedicated sample data flow profile and contains no unrelated
graphs. The following assumes all three were deployed; for GetStatus-only
setup, delete only that existing graph and the profile:

```bash
az resource delete --ids "${PROFILE_ID}/dataflowGraphs/camera-continuous-move" --api-version 2026-11-01-preview
az resource delete --ids "${PROFILE_ID}/dataflowGraphs/camera-stop" --api-version 2026-11-01-preview
az resource delete --ids "${PROFILE_ID}/dataflowGraphs/camera-get-status" --api-version 2026-11-01-preview
az resource delete --ids "$PROFILE_ID" --api-version 2026-11-01-preview
```

Have the platform owner retire only obsolete data flow graph/managed-action topic grants;
preserve the shared backend and other graph/connector access. Delete only
the Device/control Asset created for this tutorial, after checking their
`sample` and `sampleInstance` tags:

```bash
ADR_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${ADR_NAMESPACE}"
az resource show --ids "${ADR_ID}/assets/${CAMERA_ASSET}" --api-version 2026-04-01 --query tags
az resource show --ids "${ADR_ID}/devices/${CAMERA_DEVICE}" --api-version 2026-04-01 --query tags

az resource delete --ids "${ADR_ID}/assets/${CAMERA_ASSET}" --api-version 2026-04-01
az resource delete --ids "${ADR_ID}/devices/${CAMERA_DEVICE}" --api-version 2026-04-01
```

Keep the original `simulator` configuration until running the main sample's
`manage.py cleanup config.json --yes`; it removes the owned simulator
Deployment, Service, NetworkPolicy, and both credential Secrets. It does not
remove unrelated camera registrations, a shared connector template, or registry
images. If you created the ONVIF template exclusively for this tutorial, have
the platform owner remove it only after confirming that no other Device uses it.
If you created a development compatibility image, it and its registry pull
Secret are retained. Remove them separately only when no remaining connector
uses them. Published release artifacts are shared and are not part of cleanup.
Only consider deleting versions you published to your own registry, after
confirming that no other deployment uses them.
