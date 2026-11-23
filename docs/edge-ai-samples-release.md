# Deploy the edge AI samples from a coordinated release

The [person-detection sample](../samples/edge-predictive-inference/README.md)
and [MCP assistant sample](../samples/aio-mcp-ai-assistant/README.md) share one
release of their sample-owned images, data flow graph definitions, WASM modules,
and predictive model package. Customers do not need Rust, Docker builds, or
registry push permissions to use a published release.

> [!IMPORTANT]
> **Public GHCR publication is pending.** A private ACR candidate was exercised
> on 2026-11-11 with official connectors and the built-in MCP services. The
> [qualification record](edge-ai-samples-validation.md) identifies the observed
> platform, passing scenarios, and remaining model limitations. Authenticated
> private pulls do not qualify anonymous GHCR access. `0.1.0-rc.1` in the example
> configurations is still a candidate identifier, not an available release.
> Do not start a customer deployment until a coordinated public release exists
> and its qualification record covers your scenario.

## What is released together

All paths below are beneath `ghcr.io/azure-samples/explore-iot-operations`.
Every artifact in one release has the **same explicit version tag**.

| Repository suffix | Artifact |
| --- | --- |
| `edge-predictive-inference/preprocess`, `edge-predictive-inference/postprocess` | Two compiled WASM components. |
| `edge-predictive-inference/preprocess-graph`, `edge-predictive-inference/postprocess-graph` | Graph definitions referencing those exact module versions. |
| `edge-predictive-inference/yolox-nano` | Reviewed ONNX export, Apache-2.0 license, and checksum/tensor provenance. |
| `aio-mcp-ai-assistant` | Linux/amd64 assistant image. |
| `onvif-simulator` | Linux/amd64 software-camera image with a synthetic calibration scene. |
| `aio-mcp-ai-assistant/camera-actions/get-status`, `.../continuous-move`, `.../stop` | Three camera-control WASM components. |
| `aio-mcp-ai-assistant/camera-actions/get-status-graph`, `.../continuous-move-graph`, `.../stop-graph` | Three matching camera-control graph definitions. |

This is 13 artifacts, not 13 deployed services. Camera control remains optional.
Microsoft's media, inference, and ONVIF connectors, the built-in inference
transform, the AIO MCP services, and the Qwen catalog model are **not**
republished. Their versions and permissions are independent platform prerequisites.

The [Edge AI samples workflow](../.github/workflows/edge-ai-samples.yml) publishes
the complete set after checks pass on relevant pushes to upstream `main`,
including PR merges, subject to repository/environment protection rules.
Maintainers set one unused version in
[`release-spec.json`](../tools/edge-ai-release/release-spec.json) before merging;
versions are not automatically incremented or overwritten. PRs do not publish.
See the [maintainer instructions](../tools/edge-ai-release/README.md#publish-a-version)
for permissions and manual build-only runs.

## 1. Select and verify a release

Use the repository's [GitHub releases](https://github.com/Azure-Samples/explore-iot-operations/releases)
with tag `edge-ai-v<VERSION>`. Read its qualification status and check out that
tag, rather than combining its artifacts with scripts from another revision.
Qualification can finish after publication: use the evidence link in the release
notes and confirm that it names this exact version and source revision. An older
record bundled with the tag can still say pending.
The release is created only after all 13 packages pass anonymous full-content
pulls. It includes:

- `release.json`: source revision, exact artifact references, payload/config
  digests, and platform architecture.
- `verification.json`: anonymously verified manifest digests. Its
  `runtimeValidated: false` is intentional: publication is not a cluster test.

Download both files from that release's Assets section into a new local
directory, for example `.edge-ai-release`. With GitHub CLI installed, the
equivalent command from the repository root is:

```bash
RELEASE_VERSION="REPLACE_WITH_PUBLISHED_VERSION"
gh release download "edge-ai-v$RELEASE_VERSION" \
  --repo Azure-Samples/explore-iot-operations \
  --pattern release.json --pattern verification.json --dir .edge-ai-release
```

For an independent check, use Python 3.10+ with `PyYAML==6.0.3` and ORAS 1.3+:

```bash
python tools/edge-ai-release/release.py verify .edge-ai-release --published
```

The verifier uses an empty temporary registry credential file, pulls every
config and layer, checks digests and sizes, and checks graph-to-module version
references. For images it also checks the uncompressed layer identities against
the tested image config. It needs no Docker daemon, local builds, model weights,
or registry credentials. This downloads all 13 artifacts; allow corresponding
bandwidth and temporary disk space. It refreshes the local `verification.json`
only after the whole set passes. Stop on any error.

Do not use `latest`, mix versions, or assume a package is public because an
authenticated workstation can pull it. A failed publishing run can leave some
packages present; **individual tags are not a completed release**.

## 2. Configure the independent registry consumers

There are three different pull paths. Credentials for one do not authorize
the others.

| Consumer | Public GHCR release configuration |
| --- | --- |
| Kubernetes, assistant and simulator images | Explicit published image tags or digest references; `imagePullSecret: ""`. No pull secret is needed for public images. |
| AIO, graph definitions and their WASM modules | A dedicated AIO registry endpoint for `ghcr.io` with anonymous authentication. |
| Foundry Local, custom YOLOX model package | `registry: ghcr.io` and the released repository/version. The sample's custom-model manifest currently requires a Secret with `username` and `password` keys in the Foundry namespace. This is not a Docker pull secret. |

### AIO registry endpoint

Have the platform owner inspect existing registry endpoints and reuse a suitable
one, or create a **new** endpoint using the supported CLI. Substitute your
explicit resource identifiers:

```bash
SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
RESOURCE_GROUP="YOUR_RESOURCE_GROUP"
AIO_INSTANCE="YOUR_AIO_INSTANCE"
REGISTRY_ENDPOINT="edge-ai-ghcr"

az iot ops registry create \
  --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" \
  --instance "$AIO_INSTANCE" --name "$REGISTRY_ENDPOINT" \
  --host ghcr.io --no-auth
```

Do not replace an endpoint owned by another application. In particular, keep
the `default` endpoint pointing at `mcr.microsoft.com`: the inference transform
uses it. Set the sample's `registryEndpointName` to the new or approved existing
endpoint **name**, not the hostname. Both graph and module repositories must
be reachable from the data flow runtime.

### Foundry custom-model credentials

Use your approved secret-management process to provision read-only GHCR
credentials. Follow
[GitHub Container Registry authentication guidance](https://docs.github.com/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry)
and your organization's token policy. No package write permission is needed.
For an authorized local evaluation, create the Secret from protected files
without putting credential values in command history:

```bash
CONTEXT="YOUR_KUBERNETES_CONTEXT"
FOUNDRY_NAMESPACE="YOUR_FOUNDRY_NAMESPACE"
MODEL_REGISTRY_SECRET="edge-ai-model-registry"
REGISTRY_USERNAME_FILE="/secure/path/to/registry-username"
REGISTRY_TOKEN_FILE="/secure/path/to/read-only-registry-token"

kubectl --context "$CONTEXT" -n "$FOUNDRY_NAMESPACE" create secret generic \
  "$MODEL_REGISTRY_SECRET" \
  --from-file=username="$REGISTRY_USERNAME_FILE" \
  --from-file=password="$REGISTRY_TOKEN_FILE"
```

Use files containing only the value, without a trailing newline. Do not
overwrite an existing unrelated Secret, print its contents, or commit the
files. Set `modelRegistrySecret` to its name. Authentication from `docker login`
or `oras login` on the workstation is not propagated to this controller.
Anonymous custom-model pulls are not assumed until qualified against the
selected Foundry operator; do not use empty or invented credentials.

Qwen catalog access is managed separately by Foundry and may require accepting
the model's terms. This GHCR Secret does not grant catalog access.

## 3. Configure and deploy the scenarios

Keep the samples in separate Python virtual environments; their development
dependency pins are independent. Set the published release version in all the
fields relevant to your chosen scenario:

| Configuration | Release fields |
| --- | --- |
| Predictive inference | `registry: ghcr.io`, `artifactRepository: azure-samples/explore-iot-operations/edge-predictive-inference`, `artifactVersion: <VERSION>`, and the AIO `registryEndpointName`. |
| Assistant | `image: ghcr.io/azure-samples/explore-iot-operations/aio-mcp-ai-assistant:<VERSION>`, `imagePullSecret: ""`. A verified `@sha256:...` image reference is also accepted. |
| Optional simulator | `simulator.image: ghcr.io/azure-samples/explore-iot-operations/onvif-simulator:<VERSION>`. |
| Optional camera graphs | `cameraGraphs.registry: ghcr.io`, `artifactRepository: azure-samples/explore-iot-operations/aio-mcp-ai-assistant/camera-actions`, the AIO `registryEndpointName`, and the same `artifactVersion`. |

Then follow the tutorials in order:

1. [Predictive inference deployment](../samples/edge-predictive-inference/docs/deployment.md):
   render, preflight, storage/model, connector, disabled graph/camera, readiness,
   enable, and actual MQTT/file inspection.
2. [Assistant deployment](../samples/aio-mcp-ai-assistant/README.md#deploy-the-scenario):
   render, platform-role review, identities/trust, model, workloads, and direct
   tools before model-assisted questions.
3. Optional [camera control](../samples/aio-mcp-ai-assistant/docs/camera-actions.md):
   use the published simulator and graphs, register the Device/control Asset,
   validate GetStatus, then explicitly enable bounded movement.
4. Optional [recommendations](../samples/aio-mcp-ai-assistant/README.md#review-and-publish-a-recommendation):
   independently observe no delivery before approval and the exact payload
   after operator approval.

No sample `build`, `push`, `publish.sh`, or model-download command is part of
this default deployment path. Record the results using the
[qualification checklist](edge-ai-samples-validation.md). A ready Pod, accepted
ARM deployment, or empty MQTT sampling window is not end-to-end evidence.

## Customization and private mirrors

Local builds remain supported. Use your own registry/repository and a **new**
version; never overwrite a release used by another deployment. Update
`artifactRepository` together with the registry and version so that generated
graphs resolve the modules you publish. Older configurations without this field
keep their previous `azure-samples/edge-predictive-inference` or
`azure-samples/aio-mcp-ai-assistant/camera-actions` paths.

For private mirrors, copy the full dependency set, not just graph YAML or the
assistant image. Configure each of the three pull paths independently and
requalify the mirrored setup. Local publishing helpers are for customization;
official GHCR publication uses the coordinated workflow.

For an AIO registry endpoint using `ArtifactPullSecret`, the referenced
`kubernetes.io/dockerconfigjson` Secret belongs in the AIO namespace. Its
`auths` entry must match the registry hostname and include explicit `username`
and `password` fields. A credential file containing only base64 `auth`, such as
one written by ORAS, can work for image pulls yet fail in the tested AIO graph
controller with `No 'username' found`. Provision the complete Docker registry
Secret through your approved secret-management process; do not print or commit
it. This is separate from Foundry's `username`/`password` Secret.

An accepted registry endpoint or ARM graph deployment does not prove that the
graph downloaded. Check the graph's `status.healthState`, the
`aio-wasm-graph-controller` logs, and actual execution before enabling actions.
Do not treat `DataflowGraphModuleDownloadTimeout` as a camera or model failure.
After an update, an existing `Available` condition can still describe the
previous revision while new artifacts download. Confirm the selected version
in the controller/runtime logs and run the harmless GetStatus check before
movement; never repeat a timed-out movement to test readiness.

See [local inference builds](../samples/edge-predictive-inference/README.md#build-and-run-locally),
[assistant customization](../samples/aio-mcp-ai-assistant/README.md#customize-and-test-locally),
and [maintainer release instructions](../tools/edge-ai-release/README.md).
