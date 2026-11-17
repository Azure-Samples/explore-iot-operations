# Configuration reference

[Back to the tutorial](../README.md)

Use [config.example.json](../config.example.json) as the starting point for
`config.json`. [config.schema.json](../config.schema.json) describes the accepted
structure and supports editor completion. Configuration contains names and secret
references, not passwords, tokens, or private keys.

## Preview compatibility

The complete integration requires compatible platform components, not just
container images with matching version numbers.

| Component | Required contract |
| --- | --- |
| AIO application and data flow resources | `2026-09-03-preview` API. |
| Graph execution | Compatible with graph API `1.2.99` and runtime `1.1.8` requirements. |
| Media connector | `snapshot-to-fs`, registered `ExtractClip`, `CopySource`, `local-shared`, and relative `TargetPath` responses. |
| Capture and snapshot-preprocessing graphs | `0.1.0`-family contracts, including nearest-snapshot selection. Distribution tags can differ from source metadata. |
| Inference graph | `0.3.0-preview.0` contract: `Result`/`Error` envelopes, file-backed output, and returned input references. |
| YOLO postprocessing graph | `0.2.0` contract: model `id2label`, file-backed tensors, and end-to-end detection rows. |
| Foundry Local | Kubernetes predictive ONNX serving, model metadata, HTTPS, and Kubernetes service-account token authentication. |

The example selects connector image tag `1.6.0`. Confirm that the images and
contracts are supported by your particular preview installation. An older
`0.2.0-preview.0` inference graph is not interchangeable with the required graph,
even if it is the version available in your public registry.

Obtain graph references and their referenced WASM modules through your compatible
preview distribution. Graph references in configuration are relative to the
registry endpoint; they are not full registry URLs. The endpoint must be able to
pull both the graph and its modules.

For example, after supplying your actual registry and artifact reference:

```bash
GRAPH_REGISTRY=your-preview-registry.example.com
GRAPH_ARTIFACT=repository/graph-name:your-compatible-version
oras manifest fetch --pretty "$GRAPH_REGISTRY/$GRAPH_ARTIFACT"
```

Inspect the graph definition and its module references as well. Fetching an OCI
manifest alone does not establish runtime compatibility.

The model integration follows the documented
[Foundry Local bring-your-own-model behavior](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/concept-bring-your-own-models).
Use your preview release documentation for installation and graph distribution
details that are not publicly available.

## Deployment settings

All settings below are required. `$schema` is optional editor metadata. Unknown
settings are rejected so a misspelled option cannot silently take effect as a
default.

| Setting | Meaning |
| --- | --- |
| `subscriptionId` | Azure subscription UUID used for the AIO deployment. |
| `resourceGroup` | Resource group containing the existing instance and custom location. |
| `aioInstanceName` | Existing AIO instance name. |
| `customLocationName` | Existing Arc custom location name. |
| `kubeContext` | Explicit Kubernetes context; commands do not change the current context. |
| `dataClaimName` | Dedicated ReadWriteMany PVC in `azure-iot-operations`. |
| `stateClaimName` | A different, dedicated PVC in `azure-iot-operations`, with durable POSIX locking for SQLite. |
| `foundryNamespace` | Namespace watched by the Foundry inference operator. |
| `foundryTrustSecret` | Secret in the AIO namespace with the Foundry CA chain in `ca.crt`. |
| `modelRegistry` | OCI registry hostname, optionally with a port; no scheme or repository path. |
| `modelRegistrySecret` | Secret in the Foundry namespace with `username` and `password` keys for model pulls. |
| `modelTag` | Versioned tag shared by the selected model repositories; `latest` is rejected. |
| `collectorImage` | Published observer image with a registry, repository, and versioned tag or SHA-256 digest. |
| `imagePullSecret` | Kubernetes image pull Secret in the AIO namespace, using the Docker config JSON or dockercfg format. |
| `inferenceImage` | Connector image object with `registry`, `name`, and explicit `tag`. |
| `mediaImage` | Media connector image object with `registry`, `name`, and explicit `tag`. |
| `mediaTemplateName` | New sample ConnectorTemplate name, or the exact existing name when reusing a template. |
| `useExistingMediaTemplate` | Boolean: validate and reuse an existing template without overwriting it. |
| `graphRegistryEndpointName` | Existing AIO registry endpoint for compatible graphs/modules. |
| `graphs` | `capture`, `preprocessing`, `inference`, and `postprocessing` artifact references. |
| `enabledScenarios` | `["equipment-area"]`, `["pcb-quality"]`, or both, without duplicates. |
| `cameras` | Camera address and authentication objects keyed by scenario name. Every enabled scenario needs an entry. |

Names used for the sample's Kubernetes resources and references must be lowercase
DNS labels of at most 63 characters. Do not use `latest` for deployable artifacts.
Retain previous configuration and immutable model/image versions for rollback.

Model packages are expected under `.assets/models/<scenario>/package/`.
Rendering verifies the prepared model, labels, and provenance. For a different
preparation output location, invoke the renderer with `--models <directory>`.
The deployment script uses the standard `.assets/models` location.

```bash
python render.py config.json --validate-only
python render.py config.json --output .generated
```

The first command needs no model files and writes no output. The second requires
the selected prepared packages. Correct an error and render again; do not deploy
partially edited or stale generated files.

## Scenario settings

[scenarios.json](../scenarios.json) defines model names, asset names, topic
prefixes, confidence thresholds, and review policies. The renderer adds the
prepared package's label map and provenance to the observer configuration.

| Setting | Constraint |
| --- | --- |
| `name` | One of the two supported scenario identifiers. |
| `deviceName`, `assetName`, `modelName` | Unique, valid resource names. Changing them changes resource identities, not just display labels. |
| `topicPrefix` | Unique, nonempty topic levels without wildcards or whitespace. |
| `confidenceThreshold` | A **string** containing a number in `(0,1]`, because graph configuration values are strings. Default: `"0.55"`. |
| `imageSize` | `[640,640]` for these model packages. |
| `outputRows` | `300` for these end-to-end model outputs. |
| PCB policy | `defect-review`, with labels matching the packaged model. |
| Equipment-area policy | `area-review`, a packaged model label, a normalized rectangle, and `point: "box-center"`. |

Changing the threshold does not establish a model's suitability. Calibrate it
against labeled data from the actual camera and domain. The region is in model
image coordinates; it does not encode a physical distance or safety boundary.

Configuration changes roll out the observer using a configuration checksum.
The observer refuses changed settings while old inspections remain unfinished or
unpublished. Follow the [update procedure](operations.md#change-models-policies-or-scenarios).

## Identities and trust

The sample uses two application identities:

| Identity | Purpose |
| --- | --- |
| `azure-iot-operations/aioappcfg-edge-inference-sa` | Generated inference-application service account, authorized on the Foundry models. |
| `azure-iot-operations/edge-inference-observer` | Observer and walkthrough trigger client, authorized on the selected sample MQTT topics. |

The Foundry installation must accept `satAuth.audience: aio-internal` for the
AIO application token. Its usual `foundry-local` audience is not interchangeable.
An administrator must review effects on other callers before changing this
installation-level setting.

Model endpoints use
`https://<modelName>.<foundryNamespace>.svc.cluster.local:5000`.
The manifests explicitly set the model port to `5000`. Preserve certificate and
hostname verification. The inference connector trusts the CA chain from
`foundryTrustSecret`; the observer trusts the broker ConfigMap
`azure-iot-operations-aio-ca-trust-bundle`.

The observer projects an `aio-internal` token and reconnects after token rotation.
It has no Kubernetes API Role and does not mount the default API token.

## Existing installations

### Inference connector

Only one inference connector can execute per AIO instance. Its MQTT RPC executor
client ID is fixed, so a second application name does not isolate another
connector.

The deployment script detects recognizable existing inference applications, but
custom images can require administrator inspection. If a connector already
exists, merge the model entries, read/write volume paths, and Foundry trust
settings into that application. Authorize its actual generated service account
on the models. The scripted fresh-install path is not an automatic merge tool.

### Media connector template

Akri allocates assets to every template matching `Microsoft.Media`. Creating a
second matching template can cause duplicate allocation.

When reusing a template, set `useExistingMediaTemplate: true` and its exact
`mediaTemplateName`. The template owner must reconcile these settings:

```yaml
persistentVolumeClaims:
  - claimName: edge-inference-data
    mountPath: /inference-shared
additionalConfiguration:
  localSharedPath: /inference-shared/edge-inference/media
```

Use the claim named in your configuration. The script verifies this storage
layout and leaves a reused template unchanged. Do not redirect a shared template's
storage if it would break another workload. Coordinate a consistent path
adaptation or use a separate evaluation instance.

### Reserved resources

Before deploying, ensure these names are available or already belong to this
sample:

| Resource | Name |
| --- | --- |
| AIO application definition/configuration | `edge-inference` / `edge-inference` |
| Data flow profile | `edge-inference` |
| Data flow graphs | `<scenario>-capture`, `<scenario>-inference`, `<scenario>-postprocessing` |
| Observer deployment/service account | `edge-inference-observer` |
| Scenario ConfigMap | `edge-inference-scenarios` |
| Storage initialization / tensor cleanup | `edge-inference-storage-init` / `edge-inference-response-cleanup` |
| Default camera devices/assets | `edge-pcb-camera`, `edge-area-camera` |
| Default Foundry models | `edge-pcb-quality`, `edge-equipment-area` |
| Replay resources | `edge-replay-pcb-quality`, `edge-replay-equipment-area` |

Kubernetes resources created by the sample carry
`app.kubernetes.io/part-of: edge-inference-sample`. The script refuses to overwrite
unlabeled or differently labeled Kubernetes resources. ARM names are reserved for
the sample; confirm ownership before deployment or removal.

## Live cameras

For internal replay, use the supplied ClusterIP RTSP address and
`{"method":"Anonymous"}`. To use a physical camera, set its address and supported
authentication in the relevant `cameras` entry:

```json
"equipment-area": {
  "address": "rtsps://camera.example.com:322/stream",
  "authentication": {
    "method": "UsernamePassword",
    "usernamePasswordCredentials": {
      "usernameSecretName": "workcell-camera-username",
      "passwordSecretName": "workcell-camera-password"
    }
  }
}
```

Use your camera's actual URL, port, and path. Create/project the referenced secrets
through [AIO secret management](https://learn.microsoft.com/azure/iot-operations/secure-iot-ops/howto-manage-secrets).
Configure the camera CA trust through the media template's trust settings for
RTSPS, including when reusing an existing template. See
[media connector authentication and TLS](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-media-connector).
The sample does not provision a camera trust bundle automatically.

Credentials embedded in URLs are rejected. Certificate-based client authentication
is not offered by this sample's media configuration. Keep live-camera access
restricted and obtain appropriate permission for imagery containing people.

Configure a 640 x 640 camera profile or letterboxing gateway. Renaming the Device's
`rtsp` inbound endpoint or its `camera-snapshots` stream also changes the storage
contract; changing the URL alone does not require those names to change.

## Storage

Use the [storage example](../kubernetes/storage.example.yaml) only for dedicated
claims. The data claim is shared by media, inference, postprocessing, and the
observer. The state claim is writable by one observer replica and must support
SQLite durability and POSIX locking.

The non-root initialization Job creates the data directories and verifies writes
as UID/GID `65532`. Kubernetes `fsGroup` handling can adjust volume ownership;
do not use claims containing unrelated data. Do not mount a shared volume over
the media connector's private `/tmp`.

See [file layout](architecture.md#file-layout) and
[retention and sizing](operations.md#retention-and-capacity) before changing
mounts, retention, or storage classes.
