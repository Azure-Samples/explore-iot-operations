# Operations and troubleshooting

[Back to the tutorial](../README.md)

Run commands from the sample directory. The examples assume your environment
variables are initialized from its configuration:

```bash
KUBE_CONTEXT=$(jq -r .kubeContext config.json)
FOUNDRY_NAMESPACE=$(jq -r .foundryNamespace config.json)
```

## Inspect an operation

Start with the UUID printed by the trigger client. Retrieve its completed record,
or list unfinished and unpublished work:

```bash
kubectl --context "$KUBE_CONTEXT" -n azure-iot-operations \
  exec deployment/edge-inference-observer -- \
  python mqtt_client.py records --inspection-id "$INSPECTION_ID"

kubectl --context "$KUBE_CONTEXT" -n azure-iot-operations \
  exec deployment/edge-inference-observer -- \
  python mqtt_client.py records --pending

kubectl --context "$KUBE_CONTEXT" -n azure-iot-operations \
  logs deployment/edge-inference-observer --tail=100
```

`records --pending` reports `awaiting-stages` or `awaiting-publication`. It must
return no records before changing configuration or removing the observer.
`records` defaults to the 20 most recent completed observations; use `--limit`
for an intentional larger export.

The record/evidence commands only read state and do not need a broker connection,
token, or scenario configuration. The evidence command rejects missing files,
symlinks, and bytes that no longer match the recorded hash.

## Troubleshooting

| Symptom | Diagnosis and corrective action |
| --- | --- |
| Configuration validation fails | Check the reported field against `config.schema.json`. Use the nested `cameras` structure, valid resource names, explicit artifact versions, and distinct data/state claims. |
| Model or label checksum changed | Prepare the selected model again, inspect the provenance, and publish a new immutable version. Do not edit label files without repackaging. |
| Graph provisioning or module-resolution failure | Check the registry endpoint and every referenced graph/module artifact against the preview compatibility matrix. A connector image pulling successfully does not prove graph access. |
| Graph mode update refuses a profile | Inspect the complete profile for unexpected resources or pagination. The helper does not partially update an incomplete or unfamiliar listing. |
| Model deployment not `Running` | Inspect the model resource and pod events. Check predictive-runtime support, CPU/memory capacity, registry access, and the model Secret's `username`/`password` keys. |
| HTTP 401/403 from Foundry | Check `satAuth.audience: aio-internal`, projected-token rotation, and the actual inference application's authorized service account. |
| TLS validation failure | Check the CA chain, endpoint DNS name, certificate SANs, namespace, port, and the trust Secret's `ca.crt` key. Preserve TLS validation. |
| Observer not ready | Check broker reachability, `K8S-SAT`, topic permissions, and QoS 1 subscription grants. Readiness is set by the observer only after subscription acknowledgement. |
| Capture `Busy` | Serialize file operations. A media connector handles them across its assets; simultaneous requests are not guaranteed to queue. |
| No snapshot / expired event | Confirm the stream is recording, wait for finalized snapshots, synchronize clocks, and choose an event within the private buffer. |
| Shared file not found | Check `TargetPath`, final-five-segment preprocessing, PVC subpaths, and UID/GID `65532` access. Do not add an absolute-prefix workaround to this relative layout. |
| Observation timeout | Inspect the missing stages, graph state, connector logs, and correlation properties. A graph invocation can fail without delivering a later stage; the observer still expires the inspection. |
| Unexpected `NO_FINDING` | Review actual image content, domain suitability, normalization, geometry, threshold, and region. Never interpret it as quality acceptance or safety assurance. |
| Tensor/postprocessing mismatch | Verify the model and label map, `detections_0`, `[1,300,6]` output, graph versions, and the configured confidence threshold. |
| Wrong labels after model replacement | Reload the affected graph/module instances so cached model labels are refreshed, following your release's supported procedure. Keep model tags immutable. |
| Configuration changed with pending work | Restore the previous configuration and observer image, let work finish and publish, then retry the update. |
| Topic no longer configured | A persistent broker session can retain old subscriptions after a topic change. Retire the obsolete subscriptions/session through the broker's supported administration process after draining. |
| Capacity or storage failure | Export/archive published records, restore capacity, and review event rate and retention. Do not discard pending/outbox data to make the observer appear healthy. |

Inspect a specific asset rather than relying only on pod readiness:

```bash
kubectl --context "$KUBE_CONTEXT" -n azure-iot-operations \
  get asset.namespaces.deviceregistry.microsoft.com/edge-area-camera -o yaml

kubectl --context "$KUBE_CONTEXT" -n "$FOUNDRY_NAMESPACE" \
  describe modeldeployment edge-equipment-area
```

For PCB, substitute `edge-pcb-camera` and `edge-pcb-quality`. Review the
`camera-snapshots` stream and `ExtractClip` action status. For replay, inspect the
`edge-replay-<scenario>` deployment's logs if the RTSP port is open but the asset
is not recording.

## Retention and capacity

| Data | Default retention | Important behavior |
| --- | --- | --- |
| Private media snapshots | 10 minutes | Lost when the media pod restarts. |
| Shared capture copies | 60-minute age, 60-minute sweep | Removal can occur 60-120 minutes after capture time, not after copy time. |
| Completed records and evidence | 7 days after completion | Pruned only after successful publication, up to 100 records per sweep. |
| Raw response tensors | 24 hours | Cleanup runs every five minutes and deletes at most 1,000 old UUID-named regular files per run. |

The observer defaults to a 180-second inspection deadline and 10,000 stored
inspections. Configure its command arguments in the observer template if needed:
`--timeout`, `--retention-days`, and `--max-records`. Keep raw tensor retention
longer than the inspection deadline and recovery window.

These values are evaluation defaults. At two streams, one snapshot per second,
and an assumed 150 KiB per JPEG, the private ten-minute buffer alone is about
176 MiB. Shared copies, retained evidence, and tensor volume depend on **trigger
rate**, image size, and model output, rather than camera rate alone. Cleanup is
bounded and must be sized to keep pace with ingestion.

Keep one observer replica with the `Recreate` strategy. SQLite on a shared
unverified network filesystem is not a substitute for a multi-writer datastore.
For higher volume or multiple replicas, design a supported datastore and
partitioning/concurrency strategy before changing this sample's deployment.

Monitor rejected events, missing stages, latency, capture offsets, Busy responses,
outbox backlog, restart counts, and available space. Restrict access to images,
business context, and logs. Export evidence through an approved mechanism before
local expiry; the sample does not provide a cloud image-archive service.

## Change models, policies, or scenarios

1. Stop all publishers for the affected integration. Keep the previous
   configuration and immutable image/model versions for rollback.
2. Use `records --pending` until no unfinished or unpublished work remains.
   Resolve broker outages and error conditions rather than deleting outbox rows.
3. Run `bash deploy.sh disable config.json`. This disables all recognized sample
   graphs, including a scenario no longer listed in the local configuration.
4. Change the inputs, model version, configuration, threshold, or region. Prepare
   and publish changed models with a new version; review labels and provenance.
5. Render and inspect resources. For changed replay media, run
   `bash deploy.sh replay config.json` before `bash deploy.sh deploy config.json`.
   The replay configuration/image checksum rolls out a new publisher. Allow the
   new stream to record for several seconds before submitting another event.
6. If replacing a model under the same configured model name, refresh the affected
   postprocessing instances to clear cached labels using the supported preview
   release procedure.
7. Enable the graphs and run controlled positive, negative, and failure cases.
   Resume customer publishers only after accepting the new behavior.

Removing a scenario from `enabledScenarios` does not delete its old resources.
After disabling and exporting evidence, remove its explicitly named graphs,
camera, model, and optional replay resources. Do not enable those retired graphs.

The observer rejects a changed configuration while work remains pending or
unpublished. When upgrading from an earlier observer without a stored
configuration fingerprint, drain with that earlier version before upgrading.

## Acceptance before operational use

| Exercise | What to establish |
| --- | --- |
| Known positive PCB images | Correct defect labels and approximate locations under the actual optics, board family, and lighting. Quantify misses and false positives. |
| Known negative PCB images | No configured findings for the evaluated images, without turning `NO_FINDING` into automatic product acceptance. |
| Person inside/outside the area | Correct image-space box-center behavior, including boundary cases and camera padding. |
| Unavailable camera/model | Explicit `ERROR` or deadline expiry, with a useful reason; no fabricated empty success. |
| Partial capture | Retain usable evidence and warnings, producing `REVIEW` rather than an unqualified clean result. |
| Duplicate/out-of-order messages | Stable UUID correlation and one immutable terminal observation; downstream deduplication handles repeated publication. |
| Observer restart/token rotation | Recovery from durable state and outbox, successful reauthentication, and no acknowledged-but-unpersisted work. |
| Storage failure / retention | Visible failure, protected unpublished work, correct export, and removal limited to sample-owned data. |
| Sustained workload | Acceptable latency, event/capture alignment, Busy/error rates, CPU/memory use, and retention capacity. |

A static replay establishes integration behavior, not tracking performance,
hardware synchronization, model accuracy on a new domain, or a safety case.
The sample performs no equipment actuation.

## Remove sample resources

Run this procedure only for resources created exclusively for this sample.
Confirm ownership, stop publishers, drain work, disable graphs, and export required
records/images first. Namespace, instance, shared registry, Secrets, broker
policies, and platform installation are not cleanup targets.

### Remove scenario and observer workloads

Inspect the rendered files and remove only the scenarios actually deployed. For
example, for equipment-area:

```bash
kubectl --context "$KUBE_CONTEXT" delete -f .generated/camera-equipment-area.yaml \
  -f .generated/model-equipment-area.yaml
```

If replay was created:

```bash
kubectl --context "$KUBE_CONTEXT" delete -f .generated/replay-equipment-area.yaml
```

Repeat with the explicit `pcb-quality` filenames if deployed. Then remove the
common sample workloads:

```bash
kubectl --context "$KUBE_CONTEXT" delete -f .generated/collector.yaml \
  -f .generated/response-cleanup.yaml -f .generated/scenarios-configmap.json \
  -f .generated/storage-init.yaml
```

Do not bulk-delete `.generated/`. It can include claims, retained files for an
earlier scenario selection, or resources you intentionally reused.

### Remove the sample ARM resources

List the sample graph IDs before deleting them. These commands do not remove
other profiles or the AIO instance:

```bash
SUBSCRIPTION_ID=$(jq -r .subscriptionId config.json)
RESOURCE_GROUP=$(jq -r .resourceGroup config.json)
AIO_INSTANCE=$(jq -r .aioInstanceName config.json)
INSTANCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.IoTOperations/instances/$AIO_INSTANCE"
API_VERSION=2026-09-03-preview

az rest --method get --url \
  "https://management.azure.com$INSTANCE_ID/dataflowProfiles/edge-inference/dataflowGraphs?api-version=$API_VERSION" \
  --query 'value[].id' --output tsv
```

For **each reviewed sample graph**, set its exact ID and remove it:

```bash
GRAPH_ID="$INSTANCE_ID/dataflowProfiles/edge-inference/dataflowGraphs/equipment-area-capture"
az resource delete --subscription "$SUBSCRIPTION_ID" --ids "$GRAPH_ID" \
  --api-version "$API_VERSION"
```

Repeat for the deployed inference and postprocessing graphs and any PCB graphs.
After the profile is empty, remove the exclusively sample-owned profile and
application configuration, then its definition:

```bash
az resource delete --subscription "$SUBSCRIPTION_ID" \
  --ids "$INSTANCE_ID/dataflowProfiles/edge-inference" --api-version "$API_VERSION"

az resource delete --subscription "$SUBSCRIPTION_ID" \
  --ids "$INSTANCE_ID/aioApplicationDefinitions/edge-inference/aioApplicationConfigurations/edge-inference" \
  --api-version "$API_VERSION"

az resource delete --subscription "$SUBSCRIPTION_ID" \
  --ids "$INSTANCE_ID/aioApplicationDefinitions/edge-inference" --api-version "$API_VERSION"
```

Skip application deletion if you manually integrated the models into an existing
shared inference application. Remove only the sample model configuration entries
through its owner's change process.

### Review remaining storage and shared components

Delete `.generated/media-template.yaml` only if the sample created that template
and no remaining assets use it. Never delete a reused template.

PVC deletion is intentionally manual. After export and approval, delete only the
two dedicated sample claims if they are no longer needed, taking the storage
class's reclaim policy into account. Review any completed cleanup Jobs before
deleting claims they still reference.

Remove unused model and observer artifacts from the registry through your normal
retention process. Keep required provenance/notices and any rollback versions.
Revoke topic permissions only for retired sample identities/topics, without
replacing the shared broker authorizer.
