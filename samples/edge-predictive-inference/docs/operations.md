# Operations, troubleshooting, and cleanup

Operational guidance for the [person-detection scenario](../README.md).
For initial setup, use the [deployment guide](deployment.md).

Run commands from `samples/edge-predictive-inference` with its virtual environment
active. Every helper uses the configured subscription and Kubernetes context;
it does not change global defaults.

## Inspect readiness and missing results

```bash
./deploy.sh status config.json
CONTEXT=$(jq -er '.kubeContext' config.json)
PREFIX=$(jq -er '.topicPrefix' config.json)
kubectl --context "$CONTEXT" get pods -n azure-iot-operations
kubectl --context "$CONTEXT" get events -n azure-iot-operations --sort-by=.lastTimestamp
```

Select the actual connector, media, or data flow pod from that output and inspect
its logs with `kubectl --context "$CONTEXT" logs -n azure-iot-operations <pod>`.
Do not assume the managed connector's pod is named `aio-inference-connector`.

| Symptom | Check |
| --- | --- |
| No JPEGs on `<prefix>/frames` | Camera/asset enabled state, camera reachability, synchronized credentials, media connector logs, and broker publish/subscribe authorization. |
| JPEGs arrive but no observations | Graph enabled/available state, all five nodes, artifact pulls, file stores, graph logs, and connector/model readiness. |
| `no file store configured` | The parent data flow must keep both file-store entries. A mounted connector PVC alone is insufficient. Redeploy the Bicep graph if a portal edit removed them. |
| Input write or response read errors | Same claim and subpaths in graph and connector, RWX support, permissions, free space, and cleanup age versus processing delays. |
| Foundry returns 401/403 | Audience `aio-internal`, model authorization for the generated application service account, and the actual model base URL. |
| TLS failure | Secret in the AIO namespace with correct `ca.crt`, certificate hostname, and CA rotation. Do not disable certificate verification. |
| Model does not load | Foundry status/events, registry credentials and expiry, registry permissions, model artifact version, and predictive ONNX runtime support. |
| Wrong response contract | Keep the pinned 0.2 inference graph. The 0.3 envelope is not a filename. |
| Valid zero-person observations | Inspect authorized scene data, field of view, preprocessing, threshold, and the generic model's domain limitations. Zero detections is not proof of no people. |
| Increasing delays or missing frames | Start at 0.2 snapshots/sec, then assess model latency, graph capacity, MQTT limits, CPU/memory, and storage. This sample is not a throughput sizing result. |

The default model requests one CPU and 512 MiB, with limits of two CPUs and 2 GiB.
This is in addition to the connector, data flow runtime, media connector, broker,
and storage. Resource requests are starting settings, not measured capacity.

## Storage and retention

The initialization job creates `edge-predictive-inference/inputs` and `responses`
as UID/GID `65532`, with group-write/setgid permissions `2770`. The reader and
cleanup pods also use group `65532`. Confirm that your managed graph and
connector identities can access these directories. If platform identities or
storage ownership differ, have the storage owner provide appropriate group
access/ACLs; do not make a whole shared volume world-writable or patch a
controller-managed workload behind its configuration owner.

The claim must support RWX, concurrent readers/writers, and the filesystem
operations used by the graph. An `RWO` local-path claim or unrelated namespace's
claim is not a substitute. The sample intentionally keeps storage in the AIO
namespace and does not change a cluster storage class.

The CronJob runs once per minute and uses `find -mmin +5`. Minute rounding and
the sweep interval mean files can remain for roughly six to seven minutes.
Files are deleted by age, not completion acknowledgment. Keep processing time
comfortably below the retention window; overloaded/backlogged deployments need
capacity and retention review. The job reports removed filenames and fails on
filesystem errors.

There is no durable result database or retained JPEG evidence. Consume and store
observations in an application if you need a history. Protect camera data and
tensor files according to your organization's privacy/access requirements.
PVC size is fixed in the template; resizing or deleting it is an explicit
storage-owner action.

## Managed updates

The deployment helper is designed for **initial installation**. It refuses to
install a connector if one is already running, even if that workload belongs to
this sample. Update an existing application through its managed configuration.

For a deliberate update to this sample's existing application:

1. Disable the sample and confirm reconciliation.
2. Edit configuration, build changed WASM, publish a new artifact version if
   needed, and render again.
3. Inspect the changes with ARM what-if and update the **same** application
   configuration, not its generated ConfigMap/Deployment/StatefulSet.

For example, after confirming ownership:

```bash
./deploy.sh disable config.json
python render.py config.json
SUBSCRIPTION=$(jq -er '.subscriptionId' config.json)
GROUP=$(jq -er '.resourceGroup' config.json)

az deployment group what-if --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
  --template-file bicep/connector.bicep --parameters @.generated/connector.parameters.json
az deployment group create --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
  --name edge-predictive-connector --template-file bicep/connector.bicep \
  --parameters @.generated/connector.parameters.json
```

Review model authorization, endpoints, volume paths, and other existing model
entries before changing a shared connector. The one-model sample template is
not a merge operation and must not replace unrelated model configuration.

Reapply the sample's model/camera/flow resources as appropriate, verify readiness,
then enable. Updating an already completed initialization Job or an existing
reader Pod with immutable-field changes requires explicitly recreating that
sample-owned object. Do not delete the data claim just to rerun initialization.

## Stop and remove only this sample

First request shutdown and confirm that the camera and graph are disabled:

```bash
./deploy.sh disable config.json
./deploy.sh status config.json
```

The commands below are for resources created by this standalone sample.
Do **not** use them after integrating the model into a shared connector. Keep
the model, application, or claim if another workload now depends on it.

Remove the sample's ARM resources individually:

```bash
SUBSCRIPTION=$(jq -er '.subscriptionId' config.json)
GROUP=$(jq -er '.resourceGroup' config.json)
INSTANCE=$(jq -er '.aioInstanceName' config.json)
ADR=$(jq -er '.adrNamespaceName' config.json)
CAMERA=$(jq -er '.cameraId' config.json)
BASE="/subscriptions/$SUBSCRIPTION/resourceGroups/$GROUP/providers"
AIO="$BASE/Microsoft.IoTOperations/instances/$INSTANCE"
APP="$AIO/aioApplicationDefinitions/edge-predictive-inference"

az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$BASE/Microsoft.DeviceRegistry/namespaces/$ADR/assets/$CAMERA" --api-version 2026-04-01
az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$BASE/Microsoft.DeviceRegistry/namespaces/$ADR/devices/$CAMERA" --api-version 2026-04-01
az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$AIO/dataflowProfiles/edge-predictive-inference/dataflowGraphs/edge-person-detection" \
  --api-version 2026-09-03-preview
az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$AIO/dataflowProfiles/edge-predictive-inference" --api-version 2026-09-03-preview
az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$APP/aioApplicationConfigurations/edge-predictive-inference" --api-version 2026-09-03-preview
az resource delete --subscription "$SUBSCRIPTION" \
  --ids "$APP" --api-version 2026-09-03-preview
```

Remove the sample's model and inspection/cleanup resources:

```bash
CONTEXT=$(jq -er '.kubeContext' config.json)
MODEL=$(jq -er '.modelName' config.json)
FOUNDRY=$(jq -er '.foundryNamespace' config.json)

kubectl --context "$CONTEXT" delete modeldeployment "$MODEL" -n "$FOUNDRY"
kubectl --context "$CONTEXT" delete pod edge-predictive-reader -n azure-iot-operations
kubectl --context "$CONTEXT" delete serviceaccount edge-predictive-reader -n azure-iot-operations
kubectl --context "$CONTEXT" delete cronjob edge-predictive-cleanup -n azure-iot-operations
kubectl --context "$CONTEXT" delete job edge-predictive-storage-init -n azure-iot-operations
```

The PVC remains for inspection. After confirming that no remaining pod uses it
and no data must be retained, **the following explicitly deletes the sample
claim and can delete its underlying data, depending on reclaim policy**:

```bash
CLAIM=$(jq -er '.dataClaimName' config.json)
kubectl --context "$CONTEXT" delete pvc "$CLAIM" -n azure-iot-operations
```

Registry artifacts, externally managed credentials/CA secrets, broker policies,
the ADR namespace, custom location, AIO instance, Foundry installation, and media
connector template are deliberately not deleted. Review artifact retention and
revoke sample-specific topic permissions separately with their owners.

## Related documentation

- [Deploy the inference connector](https://learn.microsoft.com/azure/iot-operations/ai/inference-connector/howto-deploy-inference-connector)
- [Inference configuration reference](https://learn.microsoft.com/azure/iot-operations/ai/inference-connector/reference-inference-connector-configuration)
- [Inference in data flow graphs](https://learn.microsoft.com/azure/iot-operations/ai/inference-connector/howto-inference-connector-dataflow-graph)
- [Inference command reference](https://learn.microsoft.com/azure/iot-operations/ai/inference-connector/reference-inference-connector-commands)
