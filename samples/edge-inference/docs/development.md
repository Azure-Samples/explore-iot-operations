# Development guide

[Back to the tutorial](../README.md)

## Source layout

| Path | Responsibility |
| --- | --- |
| `inspection.py` | Scenario validation, capture selection, tensor auditing, review rules, and safe capture copying. |
| `collector.py` | SQLite lifecycle, configuration fingerprint, durable outbox, retention, and record/evidence retrieval. |
| `mqtt_transport.py` | MQTT 5 connection, TLS/SAT authentication, correlation, and manual acknowledgement. |
| `mqtt_client.py` | Observer loop and `collect`, `trigger`, `records`, `evidence`, and `clean-responses` commands. |
| `render.py`, `config.schema.json` | Checked deployment configuration, model provenance validation, and resource rendering. |
| `deploy.sh` | Explicit-context deployment, ownership checks, and graph enable/disable operations. |
| `models/` | Pinned public model catalog and deterministic ONNX preparation. |
| `bicep/`, `kubernetes/` | ARM resources and parameterized Kubernetes manifests. |
| `media/` | Editable SVG architecture, scenario comparison, and inspection sequence diagrams. |
| `tests/` | Contract, persistence, transport, rendering, and adapter behavior. |

Keep runtime dependencies in `requirements.txt`, rendering dependencies in
`requirements-deploy.txt`, and model tooling in `requirements-models.txt`.
The observer image contains only the runtime modules and dependency set, not
models, configuration, development tools, or customer images.

## Diagram sources

The files in `media/` are hand-built, self-contained SVGs, matching the Azure IoT
Operations documentation's diagram format. Edit the SVG directly; no Mermaid
renderer or diagram-generation dependency is required.

Use the Segoe UI font stack, an opaque white background, pale-blue component
boundaries, and labeled connections. Blue (`#0078D4`) denotes MQTT, dashed orange
(`#CA5010`) denotes file access, and gray (`#605E5C`) denotes RTSP/HTTPS or local
workflow steps. Keep text editable, retain the SVG title/description and Markdown
alternative text, and inspect the result at both full size and README width.
Do not embed scripts, remote fonts, or external image dependencies.

The architecture includes Azure product icons and Fluent UI System Icons.
Preserve their proportions and the [icon notices](../THIRD-PARTY-NOTICES.md#diagram-icons).
The scenario comparison describes configuration rules, not measured model output.

## Local checks

From `samples/edge-inference`:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
ruff check .
ruff format --check .
python -m unittest discover -s tests -v
shellcheck deploy.sh
```

Use `ruff format .` to apply the sample's formatting convention. Tests use
temporary fixtures and mocked external commands; they do not deploy resources,
contact a broker, download community models, or establish model accuracy.

Compile the ARM templates:

```bash
mkdir -p .generated
az bicep build --file bicep/definition.bicep --outfile .generated/definition.arm.json
az bicep build --file bicep/connector.bicep --outfile .generated/connector.arm.json
az bicep build --file bicep/dataflows.bicep --outfile .generated/dataflows.arm.json
```

The preview API can produce `BCP081` warnings because published type definitions
are unavailable. Compilation checks Bicep syntax and expressions, not the target
cluster's API support, graph artifacts, or runtime behavior.

## Model and container checks

Follow the tutorial's license review, preparation, and local smoke steps for
actual model execution. Re-running preparation with identical inputs and
dependency versions should produce the same archive. Changing the preparation
script intentionally changes the archive because that script is included.

Rebuild the observer after changing runtime modules:

```bash
docker build --tag edge-inference-observer:local .
docker run --rm --network none --read-only edge-inference-observer:local --help
```

For replay changes, verify that the pinned MediaMTX/FFmpeg container actually
publishes decodable H.264 frames. An open server port alone is insufficient.
Use an isolated environment and stop/remove only the containers you created.

## Before distributing an updated sample

Review scenario descriptions against the actual policies, update dependent
templates and documentation together, and retain accurate third-party attribution.
Keep model binaries, credentials, customer media, generated files, and local
configuration out of commits.

Complete the [preview-cluster acceptance exercises](operations.md#acceptance-before-operational-use)
with the intended release before claiming deployment or operational readiness.
Local tests, compilation, and model smoke checks do not replace that exercise.
