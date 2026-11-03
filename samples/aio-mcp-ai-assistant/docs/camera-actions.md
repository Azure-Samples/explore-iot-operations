# Add camera control through the AIO ONVIF connector

This tutorial extends the [operations assistant](../README.md) with its
`camera-pan` tool. You will build a camera simulator, connect it to the real
AIO ONVIF connector, register a Device and a PTZ control Asset, and move its
viewport through correlated MQTT managed-action requests.

**What is simulated:** the camera, its calibration scene, and physical motion.
The scene is generated at image-build time and contains no real people or
equipment. The simulator implements ONVIF SOAP and H.264 RTSP; it is not a
scripted MCP response. The MCP service, MQTT broker, AIO connector, and
Device/Asset APIs are real. This tutorial does not deploy the separate media
or person-detection pipeline.

## Prerequisites

Complete the main sample's namespace, identities, image-pull access, model,
and workload deployment first. You also need:

- Azure CLI with Bicep support and permission to deploy resources into the
  existing AIO instance, Azure Device Registry (ADR) namespace, and custom location.
- An AIO installation supporting the supplied preview ARM APIs and the ONVIF
  connector. The template pins native connector and metadata version `1.5.0`,
  whose metadata requires AIO `1.3.38` or later.
- Device/Asset resource synchronization between Azure and the cluster,
  configured by the platform owner. See
  [configure the connector for ONVIF](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-onvif-connector).
- CPU capacity for the simulator (500m CPU/512 MiB requested, 2 CPU/1 GiB limit)
  and the native connector. No GPU is required.

Use unused Device/Asset names. Do not overwrite registrations for real cameras.
If a suitable ONVIF connector template already exists, reuse it rather than
creating a second template for the same endpoint type.

## 1. Build the simulator image

From `samples/aio-mcp-ai-assistant`, with the main virtual environment active:

```bash
SIMULATOR_IMAGE="YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.0"
docker build --target test --tag aio-onvif-simulator-test ./simulator
docker build --tag "$SIMULATOR_IMAGE" ./simulator
docker push "$SIMULATOR_IMAGE"
```

Authenticate to your registry using your approved process before pushing.
The configured `imagePullSecret` must permit pulling **both** the assistant
and simulator image repositories. Repository-scoped credentials for only the
assistant do not automatically cover a separate simulator repository.
The simulator uses Python 3.12 inside the container; you do not need to change
your workstation's Python version. Its tests use generated images and local
protocol fixtures, not a physical camera.

Add the following object to the existing `config.json`, substituting your
published image. Leave `camera.enabled` false while preparing the integration:

```json
{
  "simulator": {
    "image": "YOUR_REGISTRY/azure-samples/onvif-simulator:0.1.0"
  }
}
```

This fragment is not a replacement for the complete configuration. The image
must use a valid lowercase registry/repository and a non-`latest` version tag.

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

## 3. Add the native ONVIF connector when needed

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
template.** Otherwise, validate and deploy the supplied native template:

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

The native connector image comes from Microsoft Container Registry. ARM and
AIO own its runtime reconciliation; the assistant does not directly create a
connector Pod. An allocated connector may appear only after registering an
enabled ONVIF Device. No Event Grid or cloud managed-action gateway is needed
for this local broker-to-connector path.

### Numeric non-root image compatibility

The published `1.5.0` image declares its existing UID/GID 65532 account by the
name `nonroot`. An operator-generated Pod with `runAsNonRoot: true` and no
explicit numeric UID can therefore fail with:

```text
image has non-numeric user (nonroot), cannot verify user is non-root
```

The camera integration was exercised using the included
[`onvif-connector-compat/Dockerfile`](../onvif-connector-compat/Dockerfile).
It pins the official `1.5.0` base digest and changes only `USER` to
`65532:65532`; the native connector filesystem and entrypoint are unchanged.
This is a packaging workaround, **not a mocked or reimplemented connector**.
It does not qualify the unmodified image on affected installations.

If your installation has this issue, build the wrapper and provide pull access
in the **AIO namespace**, separate from the sample namespace's pull Secret:

```bash
ONVIF_REGISTRY="YOUR_REGISTRY"
ONVIF_IMAGE_NAME="azure-samples/onvif-connector"
ONVIF_IMAGE_TAG="1.5.0-numeric-user.1"
ONVIF_PULL_SECRET="YOUR_AIO_NAMESPACE_PULL_SECRET"
ONVIF_IMAGE="${ONVIF_REGISTRY}/${ONVIF_IMAGE_NAME}:${ONVIF_IMAGE_TAG}"

docker build --platform linux/amd64 --tag "$ONVIF_IMAGE" ./onvif-connector-compat
docker push "$ONVIF_IMAGE"

kubectl --context "$CONTEXT" -n "$AIO_NAMESPACE" get secret "$ONVIF_PULL_SECRET" -o name

az deployment group validate \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-onvif --template-file bicep/onvif-connector.bicep \
  --parameters aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    connectorTemplateName="$CONNECTOR_TEMPLATE" connectorRegistry="$ONVIF_REGISTRY" \
    connectorImageName="$ONVIF_IMAGE_NAME" connectorImageTag="$ONVIF_IMAGE_TAG" \
    connectorImagePullSecretName="$ONVIF_PULL_SECRET"

az deployment group create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --name edge-assistant-onvif --template-file bicep/onvif-connector.bicep \
  --parameters aioInstanceName="$AIO_INSTANCE" customLocationName="$CUSTOM_LOCATION" \
    connectorTemplateName="$CONNECTOR_TEMPLATE" connectorRegistry="$ONVIF_REGISTRY" \
    connectorImageName="$ONVIF_IMAGE_NAME" connectorImageTag="$ONVIF_IMAGE_TAG" \
    connectorImagePullSecretName="$ONVIF_PULL_SECRET"
```

Have the registry/platform owner create that pull Secret through the approved
credential workflow with read access to the selected repository. Do not put
registry passwords in this template or configuration. Keep `runAsNonRoot`
enabled; do not patch generated Pods or disable admission controls.
Use a compatible official image instead when one is available and validated.

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

## 5. Enable only the configured action route

Set these values inside the existing `camera` object in `config.json`:

```json
{
  "enabled": true,
  "assetName": "edge-assistant-camera-onvif",
  "profileToken": "profile_high"
}
```

Use your actual control Asset name if different. Then rerender:

```bash
python manage.py render config.json
```

Have the broker owner merge the generated rule into the authorization policy
attached to the assistant's configured TLS listener. For the default Asset,
camera enablement adds Publish on exactly:

```text
azure-iot-operations/asset-operations/edge-assistant-camera-onvif/PTZ/ContinuousMove
azure-iot-operations/asset-operations/edge-assistant-camera-onvif/PTZ/Stop
azure-iot-operations/asset-operations/edge-assistant-camera-onvif/PTZ/GetStatus
```

It adds Subscribe on
`clients/edge-assistant-<sample-namespace>/camera/response`.
Existing observation subscriptions remain unchanged. Preserve all unrelated
broker rules, listener ports, and authentication settings.

The native ONVIF connector uses its own platform-managed broker identity.
Its listener/policy must independently allow the managed-action request
subscriptions and replies to the sample's response topic. Do not grant the
assistant wildcard Publish permission to compensate for a connector policy
problem.

Deploy the changed assistant settings:

```bash
python manage.py workloads config.json
python manage.py check config.json
```

## 6. Run a direct action, then a model request

```bash
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

The sidecar subscribes to the response topic before sending a command, uses
fresh correlation data for each request, requires successful MQTT
acknowledgements, and ignores stale/uncorrelated replies. `ContinuousMove`
includes a device-side timeout. An explicit `Stop` is attempted even if the
move request fails, and a successful result requires `GetStatus` to report
`IDLE` with a numeric pan position.

Inspect the simulator logs independently:

```bash
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs \
  deployment/edge-assistant-camera --tail=80
kubectl --context "$CONTEXT" -n "$NAMESPACE" logs \
  deployment/edge-assistant -c mqtt-mcp --tail=80

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

1. Keep `camera.enabled: false` and remove its Publish grants while preparing
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
   that target. Omit `simulator` if no software camera is needed.
5. In a controlled maintenance window, enable the exact-topic grants and
   camera setting, deploy, and test the smallest permitted direct movement
   before model-assisted use. A fixed speed of 0.35 and a one-second minimum
   are built into this sample; do not use it on hardware for which these
   bounds are unsuitable.

This sample is not a safety controller. Network loss can prevent Stop or its
confirmation; a timeout/error is not proof that physical motion stopped.
The independently configured device timeout and hardware safeguards remain
essential. A separate media/inference deployment is required to produce
observations from the real camera's stream.

## Clean up

Disable camera actions and remove their exact-topic grants first. Delete only
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
The compatibility image and its registry pull Secret are also retained. Remove
them separately only when no remaining connector uses them.
