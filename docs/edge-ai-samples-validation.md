# Edge AI samples: deployment qualification

## Current result

**Partial private qualification completed on 2026-11-11; there is not yet a
fully qualified public customer release.** The software-source person-detection
pipeline, built-in MCP resource/telemetry tools, direct and model-selected
simulated pan, and operator-authored recommendation approval passed.

The configured Qwen CPU model **did not pass observation interpretation,
empty-error-window interpretation, or recommendation generation**. Some resource
answers also made unsupported health claims. These are failed acceptance checks,
even when the API returned `status: "completed"` and generation ended with
`stop`. Do not describe the conversational scenario as fully qualified or use
its answers to establish occupancy, device health, or pipeline health.

All 13 sample-owned artifacts were pulled and verified from private ACR with
repository-scoped read-only credentials. Public GHCR publication and anonymous
pull verification remain pending. The example `0.1.0-rc.1` tag is not an
available release. A private authenticated deployment does not qualify public
registry access or turn the preview components into a generally supported
platform combination.

## Tested source and artifacts

| Evidence | Recorded value |
| --- | --- |
| Private candidate | `0.1.0-acr.20261111.2`; new immutable tags, not overwritten first-candidate tags. |
| Source base | `1791f313449059fa2a4940f75421c2d6b520f97e`. |
| Build source | Dirty working-tree snapshot; tracked build-patch SHA-256 `a52d5a707228566130002bd02d3a41b7e2b3e117839825d4d3cdba7fce9092f6`. |
| Artifact verification | Full config/layer pulls, descriptor hashes and sizes, both image configuration identities, source/version labels, and all five graph-to-module version references. |
| Deployment mode | Prebuilt Linux/amd64 assistant/simulator images, five graph definitions, five WASM components, and one ONNX model package pulled by their actual consumers. |
| Public release | Not published; no anonymous GHCR verification or public release ledger is claimed. |

The base commit alone does **not** reproduce this dirty build. Documentation
updates made after the image build are not part of its source snapshot. The
earlier private candidate `0.1.0-acr.20261111.1` used streaming model requests;
the complete pipeline checks were repeated on `.2` after the assistant's
non-streaming transport change. The results below refer to `.2` unless stated
otherwise.

Sanitized evidence is reproduced in this record. Raw responses, deployment
inventories, source patches, and verification ledgers are retained privately;
they are not public release assets. Private registry/resource identifiers,
credentials, and operational log dumps are intentionally omitted.

<details>
<summary>Verified private-candidate artifact manifest digests</summary>

These are manifest digests, not image configuration or uncompressed layer
digests. Repository suffixes omit the private registry prefix.

| Repository suffix | Manifest digest |
| --- | --- |
| `aio-mcp-ai-assistant` | `sha256:274446897cf64e5afc6db0a96f0eaa2ef85bd6848865853bb3fa0183f96aa803` |
| `onvif-simulator` | `sha256:5ebe56af11159790a890f471b872d1be40738d8514ed5606285ded0f62a37ea1` |
| `edge-predictive-inference/yolox-nano` | `sha256:a78eef05580551b05f4eb94cee2a905d326ff70fffdc2396dea99ff80610cb59` |
| `edge-predictive-inference/preprocess` | `sha256:a3f9128849dad38785110312d21416cd771348d4702de6b7e1d81ab6f44c1988` |
| `edge-predictive-inference/preprocess-graph` | `sha256:b21c6e650365ea323e98ae4c8f338fa6418f0e649b66640f72ac42367455017d` |
| `edge-predictive-inference/postprocess` | `sha256:17c7ba47039e1eab7a6c3b50177bee163d98cd30c645f89d6230949a0b1b7926` |
| `edge-predictive-inference/postprocess-graph` | `sha256:be9ca2b6fba916c27b1d6918abcd4e1b734d529b3241067a364d9694242cea86` |
| `aio-mcp-ai-assistant/camera-actions/get-status` | `sha256:fbc56a234da64f22db2bcfc32fd6fec0b548e90442728b5eef0e045cf4af2160` |
| `aio-mcp-ai-assistant/camera-actions/get-status-graph` | `sha256:44acd746f577659171681f0d56056a1685016293d0c8f3dd0a128e5fc332dcf8` |
| `aio-mcp-ai-assistant/camera-actions/continuous-move` | `sha256:602ba5eb2f19868dc2bb8db3cf6e91141506380c4d455fc46d6c396ceb8dd48a` |
| `aio-mcp-ai-assistant/camera-actions/continuous-move-graph` | `sha256:3fd69eecbe5daf5c3763cd5b41a809871ea76b93aeebe881c7a44cdc3d7a2e96` |
| `aio-mcp-ai-assistant/camera-actions/stop` | `sha256:45413fe5edc0921a5bdd02e0191f10240e4a495265cca3e81390ee73d35e17ba` |
| `aio-mcp-ai-assistant/camera-actions/stop-graph` | `sha256:8d6da60f29aa055a6d98b201f809d2df555f0ec9668d8a90b8cf83824e6394e1` |

Graph definitions embed their module repository/version references. Rebuilding
for the public repository prefix produces different graph artifacts; do not
substitute a GHCR hostname into these identities and assume equivalence.

</details>

## Observed platform combination

This is one observed **preview integration environment**, not a compatibility
matrix or a statement that every listed preview is available to every customer.
Have the platform owner confirm access and support before reproducing it.

| Component | Observed version / configuration |
| --- | --- |
| Kubernetes / compute | AKS `1.36.5`, Linux/amd64; two `Standard_D4ds_v5` nodes and one dedicated `Standard_D8ds_v5` Azure Linux 3 CPU node. |
| AIO Arc extension | `1.6.0-preview.60`, integration release train. |
| Akri operator | `1.4.0-preview.9`. |
| Data flow runtime, operator, webhook, and WASM controller | `1.7.3`. Custom graph artifacts declare API `1.7.2`, runtime `1.1.8`, and use preview SDK `1.7.4`; those contracts are not the platform image version. |
| Built-in MCP frontend / backend | Both `0.1.3`; HTTPS, frontend SAT audience `aio-mcp-frontend`, approved `Reader`, `DataReader`, and `Admin` access for the tested tools. |
| Media / ONVIF connectors | Official `1.6.5` images and metadata, numeric UID/GID `65532`; no compatibility wrappers or non-root policy exceptions. |
| Inference connector | Official `0.1.2`. |
| Built-in inference graph | `azureiotoperations/graph-dataflow-inference:0.2.0-preview.0`, manifest `sha256:4a3ca352ad900e459785674c3a2648c9b5a1f73583e8dbdb73c653471704c52d`. |
| Foundry Local | Arc extension, operator, predictive CPU, and generative CPU serving images `2.261102.2`; stable release train, extension automatic minor upgrades disabled. |
| Foundry networking | Gateway API `1.4.0` experimental and Istio `1.30.5`; internal HTTPS and SAT audience `aio-internal`; CA verification retained. |
| Qwen | `azureml://registries/azureml/models/qwen3.5-2b-text-generic-cpu/versions/1`; CPU, 4 CPU/4 GiB requests and 8 CPU/8 GiB limits. |
| Predictive model | Reviewed YOLOX `0.1.1rc0` Nano export, packaged with candidate `.2`; real input `[1,3,416,416]` and output `[1,3549,85]`. |
| Shared storage | Azure Container Storage enabled by Azure Arc (ACSA) `2.15.1`, automatic minor upgrades disabled; dedicated 2 GiB RWX claim using `unbacked-sc`. |
| Deployment tools | Azure CLI `2.92.0`, Bicep `0.37.4`, matching `kubectl` `1.36.5`. |
| Input / movement scope | Software RTSP camera with calibration and licensed positive-image fixtures; all PTZ movement simulated. No physical camera was qualified. |

<details>
<summary>Observed Linux/amd64 platform image identities</summary>

These are running-container `imageID` digests, not necessarily multi-architecture
tag/index digests.

| Component | Running image digest |
| --- | --- |
| Data flow runtime | `sha256:44395a74f1fbef3af634bcb4be99874c3c4d429304d4cd979ec5f0f2ccddb742` |
| Data flow operator | `sha256:880a28172a0fa3268d3f537b94c53b91bad04f3c092c0b98510bcb8992dbec86` |
| MCP frontend | `sha256:42ac71e70d232a3a0c6d2836326a2d5d50d8b32d8addb6cb8e64e1d1a099b0ba` |
| MCP backend | `sha256:e4f69c0e25f3013a89d928aac7a9ca0609d0aa5b340dc83fa8fab79ae697d461` |
| Media connector | `sha256:1437d0e45f8ffd54a56369e16be1d7e14c558f734e57ec2335c7751e4b4d92f7` |
| Connector for ONVIF | `sha256:1f06ed755de3ad362ab59a7e366e8259f0325a9ce41b21dd9067c0949caa4a6c` |
| Inference connector | `sha256:ff6912253a300bf3769d0dac12f4c70fcf3a8c5f204016b2f9fcfe1dbc943495` |
| Foundry operator | `sha256:4e6c5ec9b5e07b3d149159ff214b09175853911d83de5dfe4b53ab1445740f29` |
| Foundry generative CPU serving | `sha256:c7f1b6466b443f4f6c357c3a3166c09537bd333bd01b65a07d67181dfabbb6b6` |
| Foundry predictive CPU serving | `sha256:bee2e7b7b3ba87c67b4d6be37f06d9299eba1161919ea96ab7fdf110d75128cc` |

</details>

### Platform and registry preparation used

Reuse the platform's existing AIO, certificate, trust, and gateway controllers.
The [Foundry installation guide](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/foundry-local/deploy-foundry-local-arc-extension)
and platform owner remain authoritative for installation. The tested Foundry
extension used `2.261102.2` with its supported `storeModel.cacheJob.resources`
settings: requests of `500m` CPU / `4Gi`, and limits of `2` CPU / `8Gi`.
Its default larger cache-job request did not fit the original smaller nodes.
Qwen needs four **allocatable, available** CPUs; a four-vCPU node is insufficient
after Kubernetes reservations. Reserve suitable capacity before deploying it.

Configure ACSA and run the [cross-node storage check](../samples/edge-predictive-inference/docs/shared-storage.md)
before enabling the camera. The two verification pods exchanged checksummed
files as UID/GID `65532` on different nodes. The real graph and inference
connector subsequently exchanged tensor files across nodes. Azure Files had
been blocked by a subscription policy prohibiting Storage Shared Key access;
the ACSA path did not weaken that policy.

Configure the [three independent registry consumers](edge-ai-samples-release.md#2-configure-the-independent-registry-consumers):
Kubernetes image pulls, AIO graph/module pulls, and Foundry custom-model pulls.
The private run used repository-scoped read-only ACR credentials, separate
namespace Secrets, and a dedicated AIO registry endpoint. Its AIO Docker
credential entry needed explicit `username` and `password`, not just `auth`.
The default MCR endpoint was preserved. No credential values belong in this
record or the example configurations.

## Acceptance results

The commands below are the checked-in tutorial commands with environment-specific
configuration. Direct `tool` commands do not call the text model. The simulator
supplies real RTSP/ONVIF protocol responses, not scripted MCP/model answers.

| Check | Actual result |
| --- | --- |
| Prebuilt artifact integrity | **Passed privately:** all 13 full pulls and five matching graph/module references. Anonymous GHCR access remains **not run**. |
| Storage and model | **Passed:** cross-node checksums and real tensor exchange; correct CPU models serving through verified HTTPS/SAT endpoints. |
| Media-to-observation | **Passed:** nine fully decoded 640 x 360 JPEGs across the three scenes below; actual result counts `0/1/0`. |
| Tensor correlation | **Passed:** each scene's observed `frameId` matched its request filename and response reference; retrieved finite input/output tensors had the expected shapes. |
| Source outage and recovery | **Passed:** only the sample-owned simulator was stopped; after a 30-second drain, no result arrived in a 20-second observation window. Processing resumed after restoration without restarting the shared media connector. Malformed-model-output injection was not part of this live check. |
| MCP resource tools | **Passed:** all four built-in resource tools; the Asset's Device reference and referenced Device endpoint matched independent reads of `assets.namespaces.deviceregistry.microsoft.com` and `devices.namespaces.deviceregistry.microsoft.com`. |
| MQTT tools | **Passed:** real producer JSON, frame ID, count, and sampling time; an unconfigured source failed explicitly with `No approved telemetry source matches stage/machine_id`. |
| Model-assisted resource questions | **Mixed, not generally qualified:** an explicit named ONVIF Asset field request was grounded. A general question misinterpreted available reference fields; the companion media Asset question reported correct reference values but added unsupported Device-health claims. |
| Model-assisted observation question | **Failed:** the requested tool returned a real frame ID and `personCount: 0`; the answer omitted the requested fields and incorrectly concluded the physical scene was empty. |
| Model-assisted error-window question | **Failed:** the tool returned `messages: []`, `count: 0`, `timedOut: true`; the answer incorrectly claimed this proved a healthy pipeline. |
| Camera GetStatus | **Passed after artifact loading:** correlated real connector response, finite position, `stopConfirmed: true`, and `IDLE`. An initial post-update timeout is recorded below. |
| Direct simulated pan | **Passed:** one-second left pan at speed `0.35`, position `0.50` to `0.15`, explicit Stop and final `IDLE`. |
| Model-selected simulated pan | **Passed for this request:** actual `camera-pan` call, one-second left pan, `0.15` to `-0.20`, explicit Stop, final `IDLE`, and an accurate complete answer. Independent authenticated simulator status agreed within floating-point tolerance. |
| Digest replay regression | **Passed live:** identical and modified-body replays both returned HTTP `401`; the modified request did not reverse the accepted movement. |
| Selective Stop regression | **Passed live:** Zoom-only Stop left PanTilt moving until its original one-second deadline; both were `IDLE` afterward. |
| Operator-authored recommendation | **Passed:** independent consumer received exactly one reviewed payload after approval; none before approval, after denial, or after reused/expired approvals. Same-key duplicate publication was suppressed. |
| Actual approval expiry | **Passed:** waited 305 seconds for the real 300-second expiry; approval was rejected while the same assistant Pod and restart counts remained unchanged. |
| Model-generated recommendation | **Failed safely:** invalid tool markup, `Tool call contains text outside a parameter`; no valid approval request was produced. Direct approval success does not qualify this model flow. |
| Restored disabled actions | **Passed:** movement was rejected; recommendation returned `status: "disabled"`, `published: false`, and no approval. Independent status showed unchanged pan/`IDLE`; the consumer received no messages in a 20-second window. |
| Full cleanup | **Not run by owner request:** the approved environment and private artifacts were retained. This does not qualify full teardown. |

### Predictive scene evidence

The positive fixture was the licensed [NASA Commons photograph S99-00858](https://www.flickr.com/photos/nasacommons/16504233985/),
made available with no known copyright restrictions. Its downloaded JPEG
SHA-256 was `5b4c37d7c442bb63a069874ceb619343875a9596bca759b15afdb87f03cf3a31`.
A test-only read-only mount supplied it to the simulator; the prebuilt image
was not repackaged. This is a person-containing **recorded image**, not live
capture, an occupancy test, or a model-accuracy evaluation.

| Scene | Fully decoded MQTT JPEGs | Observed person counts | Correlated tensor evidence |
| --- | --- | --- | --- |
| Calibration | 3, each 19,334 bytes / 640 x 360 | `0, 0, 0` | Finite `[1,3,416,416]` input, range `[28,255]`; `[1,3549,85]` output. |
| Licensed person-containing image | 3, each 48,007 bytes / 640 x 360 | `1, 1, 1` | Same shapes; input range `[0,255]`; actual result/request/response correlation. |
| Restored calibration source | 3, each 19,334 bytes / 640 x 360 | `0, 0, 0` | Same shapes and original calibration checksum; new frame/request/response correlations. |

The calibration JPEG checksum was
`aaeb150d2f0f3733119268cab69af1731e11e7b190b0496cb0ab378bed7fa244`.
The positive-scene JPEG checksum was
`e842bcaf9fbf194933e444adfc1241a74394fecacea4e748dacba20506ae9f34`.
These identify complete JPEG payloads, all of which were fully decoded.
Repeated scene content does not make the separately generated frame IDs or
observations interchangeable.

### Model and action evidence

The [README's observation, error-window, simulated-pan, and recommendation questions](../samples/aio-mcp-ai-assistant/README.md#run-and-observe),
plus named-resource questions, were sent through the rebuilt assistant to the
real Foundry model and built-in MCP services. Completed resource, observation,
error-window, and camera questions each recorded two `stop` completions. The
observation and error-window answers still failed the semantic checks above.
No generated answer was repaired, replaced with operator text, or counted as a
pass because its HTTP request succeeded.

For the recommendation check, the operator asked the model to read up to two
configured assets and prepare a LOW-severity configuration-review proposal.
The strict parser rejected the malformed tool call. This is different from a
valid proposal being denied: there was no valid model-generated approval
request to review.

The direct approval check used clearly labeled synthetic qualification evidence
and a dedicated non-operational topic. An independently authenticated subscriber
compared the exact approved payload, including its idempotency key. Denied,
consumed, expired, and duplicate cases did not generate additional messages.
Pending approvals and the successful-key ledger remain in memory; these checks
do not establish durable exactly-once delivery.

## Findings resolved during qualification

**Foundry request protocol.** Real streaming questions on Foundry `2.261102.2`
coincided with readiness timeouts and HTTP `503`. The installed streaming handler
iterated a blocking SDK iterator on its async event loop; the supported complete
JSON handler offloaded generation to a worker thread. A comparison with the
actual tool prompt completed in 21.67 seconds while all eight concurrent health
requests returned HTTP `200` in 4-31 ms.

Candidate `.2` therefore requests bounded non-streaming OpenAI-compatible JSON.
The complete model questions above subsequently ran without that transport
failure. TLS, SAT authentication, time/size limits, original model text, and
finish reasons remain intact. No vendor probes, generated workloads, gateway
authentication, or model answers were patched. Fixing this transport did not
fix the model's interpretation errors.

**Graph update readiness.** The first GetStatus after updating the candidate
timed out while graph/module downloads were still reconciling. An existing
`Available` condition was insufficient to establish the updated revision's
readiness. After the new artifacts loaded, read-only GetStatus succeeded, and
only then did direct movement proceed. Confirm the selected artifact version
in controller/runtime logs and run the harmless status check; do not repeat a
timed-out Move as a readiness probe.

**Official connector compatibility.** The official media/ONVIF `1.6.5` images
worked with the installed non-root policy. Earlier named-user and incomplete-JPEG
failures are historical diagnostics, not required private-image dependencies.
See the [media compatibility notes](../samples/edge-predictive-inference/docs/deployment.md#media-connector-compatibility)
and [camera tutorial](../samples/aio-mcp-ai-assistant/docs/camera-actions.md).

## Retained environment

The owner requested that the installed platform, additional CPU node, models,
storage, software camera, and private artifacts remain available. The final
assistant configuration again disables both camera movement and recommendation
publication, and those disabled behaviors were checked live. The simulator is
`IDLE`; the inference producer remains available.

The running test workloads retain their private ACR references; they were not
pointed at nonexistent public images. Checked-in example configurations and
the release specification retain GHCR defaults. Retained compute/storage can
incur charges, and temporary registry credentials must be renewed before later
pulls after their expiry. Full sample cleanup remains a separate unrun check.

## Reproduce and promote a customer baseline

Follow the [coordinated release and registry guide](edge-ai-samples-release.md),
then the [predictive deployment](../samples/edge-predictive-inference/docs/deployment.md),
[assistant deployment](../samples/aio-mcp-ai-assistant/README.md#deploy-the-scenario),
and optional [camera tutorial](../samples/aio-mcp-ai-assistant/docs/camera-actions.md).
Keep actions disabled until direct dependency checks pass. Use only a
sample-owned source for outages and only the authorized software camera for
this movement baseline.

Before promoting a complete conversational customer path, resolve and requalify
the failed model interpretation/proposal cases, not just endpoint availability.
Commit the intended source, publish a new coordinated immutable release, verify
all public artifacts anonymously, and repeat the selected scenario checks with
those exact artifacts. A private graph's embedded repository references and a
dirty-source build are not substitutes for that release.

Link the final record from the GitHub release using its permanent commit URL.
Qualification documentation can be committed after publication; do not move a
release tag or overwrite its artifacts to add the record. Update example
versions only to the actual published, appropriately qualified release.
Physical cameras, GPU inference, detection accuracy, full teardown, and durable
recommendation delivery require separate validation.
