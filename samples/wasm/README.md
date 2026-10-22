# Azure IoT Operations WASM samples for Rust

This workspace is structured for the Azure IoT Operations VS Code extension so the `operators/` folder and graph YAML files sit side by side. Use it to build and run WASM operators locally before deploying them.

## Layout

- `operators/` – Rust operator source
- `graph.dataflow.yaml` – default graph for the extension (copy of the complex sample)
- `graph-complex.yaml`, `graph-otel.yaml`, `graph-otel-transform.yaml`, `graph-simple.yaml` – additional graphs
- `data/`, `data-and-images/`, `images/` – sample inputs; extension runs write output to `data-and-images/output`
- `schema-registry-scenario/`, `statestore-scenario/` – scenario source code YAMLs for schema registry and state store usage
- `tests/` – automated test cases for the CLI test runner and VS Code Test Explorer (auto-discovered when `wasm/` is opened as a workspace)
- `Dockerfile`, `Makefile`, `.cargo/` – Rust builder assets co-located here (see **Rust builds**)
- [`../wasm-python`](../wasm-python/README.md) – Python operator workspace; see its README for language-specific guidance

## Quick start with the VS Code extension

1. Install VS Code plus the Azure IoT Operations data flow extension (v0.4.13 or later) and ensure Docker is running. The RedHat YAML extension is optional but helpful.
2. Open `samples/wasm` in VS Code.
3. Build operators: `Ctrl+Shift+P` → **Azure IoT Operations: Build All Data Flow Operators** → choose **release**. The extension builds every project under `operators/`.
4. Start the development environment container:  `Ctrl+Shift+P` → **Azure IoT Operations: Start Development Environment**→ pick **release**. The devx container should start.
5. Run the sample graph: `Ctrl+Shift+P` → **Azure IoT Operations: Run Application Graph** → pick **release** → select `graph.dataflow.yaml` → choose the `data-and-images` folder when prompted for input. Logs and output land under `data-and-images/output`.
6. Explore other graphs by choosing a different YAML in step 4 (for example `graph-otel.yaml` or `graph-simple.yaml`).

## Rust builds (Docker builder)

Run these from `samples/wasm`:

```bash
# Release build for a specific operator
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name my-operator

# Debug build with symbols
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name my-operator --build-mode debug
```

Output lands under `operators/<name>/bin/<arch>/<mode>/`. CI uses the `Makefile` in this folder to package modules from `operators/`.

### Rust development essentials

- Install toolchain + target:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
  rustup target add wasm32-wasip2
  ```
- New operator template (minimal `Cargo.toml`):
  ```toml
  [package]
  name = "my-rust-operator"
  version = "0.1.0"
  edition = "2021"

  [dependencies]
  wit-bindgen = "0.22"
  wasm_graph_sdk = { version = "=1.1.3", registry = "aio-wg" }
  serde = { version = "1", default-features = false, features = ["derive"] }
  serde_json = { version = "1", default-features = false, features = ["alloc"] }

  [lib]
  crate-type = ["cdylib"]
  path = "src/lib.rs"
  ```
- Map operator pattern:
  ```rust
  use wasm_graph_sdk::macros::map_operator;
  use wasm_graph_sdk::logger::{self, Level};

  #[map_operator]
  fn transform_data(timestamp: HybridLogicalClock, input: DataModel) -> Result<DataModel, Error> {
      logger::log(Level::Info, "my-operator", "Processing data");
      Ok(input)
  }
  ```
- Filter operator pattern:
  ```rust
  use wasm_graph_sdk::macros::filter_operator;

  #[filter_operator]
  fn temperature_filter(_ts: HybridLogicalClock, input: DataModel) -> Result<DataModel, bool> {
      Ok(matches!(input, DataModel::Temperature(temp) if temp.value > 0.0))
  }
  ```
- More operators live in `operators/` (temperature, humidity, format, snapshot, collection, enrichment, window, viconverter) for fuller examples and configuration patterns.

## Data flow pattern samples

The [`dataflow-patterns/`](dataflow-patterns/) sample provides custom Rust graphs
for correlation, prediction, and stateful reading processing.

All fixture messages, identifiers, coefficients, and numerical results are
synthetic or illustrative. They aren't customer telemetry, customer-calibrated
models, or evidence of a customer's process behavior.

| Graph | Input | Operation | Output |
| --- | --- | --- | --- |
| `graph-align-by-time` | Separate speed and temperature messages, plus ticks | Select the latest eligible temperature at or before each speed timestamp | An aligned record, or a batch when several readings become ready |
| `graph-correlate-by-id` | Predictions and delayed measurements | Buffer either arrival order and match asset, piece, and optional run IDs | A completed match with prediction residual and target error |
| `graph-versioned-predictor` | Readings and externally approved model updates | Activate only the expected next version; evaluate readings with the active model | Predictions only; update acknowledgments don't re-enter the data path |
| `graph-report-by-exception` | Readings and trusted ticks | Compare with the last reported value; optionally send a heartbeat | Initial reading, meaningful changes, and configured heartbeats |
| `graph-stable-alarm` | Readings and trusted ticks | Apply separate raise/clear thresholds and persistence intervals | Alarm transitions |
| `graph-offline-detection` | Readings, expected-asset registrations, and trusted ticks | Check elapsed time since the last accepted measurement | Online, offline, and recovery transitions |
| `graph-running-total` | Sequenced readings and approved resets | Add values within an epoch and validate reset versions | Updated totals and reset checkpoints |
| `graph-smooth-readings` | Sequenced readings | Blend the current value with the previous smoothed value | One smoothed value per accepted reading |

### Build and exercise the operators

Use the public SDK registry configured in `samples/wasm/.cargo/config.toml`.
Install Rust with the `wasm32-wasip2` target, then run:

```bash
cd samples/wasm/dataflow-patterns
make test check build
cargo run --locked --example replay -- fixtures/align-by-time.json
cargo run --locked --example replay -- fixtures/correlate-by-id.json
cargo run --locked --example replay -- fixtures/versioned-predictor.json
cargo run --locked --example replay -- fixtures/report-by-exception.json
cargo run --locked --example replay -- fixtures/stable-alarm.json
cargo run --locked --example replay -- fixtures/offline-detection.json
cargo run --locked --example replay -- fixtures/running-total.json
cargo run --locked --example replay -- fixtures/smooth-readings.json
```

The fixtures contain input messages and expected results. [`contracts.json`](dataflow-patterns/contracts.json)
defines the exact fields, configurable bounds, counters, batch envelopes, and
restart requirements. Native fixture replay isn't a substitute for deployment
testing against an Azure IoT Operations runtime.

The published `1.0.0-rc.2` chart and both WASM modules passed actual MQTT
verification on the public AIO 1.6 runtime, followed by the chart's packaged
`helm test` on a fresh release. The [validation summary](dataflow-patterns/validation/1.0.0-rc.2.json)
records the workflow, immutable digests, runtime image and exercised cases.
This is finite functional validation, not a production durability or safety claim.

### Deploy the matching release

The GitHub workflow [Dataflow pattern WASM samples](../../.github/workflows/dataflow-patterns.yml)
builds the locked Rust sources, tests the chart, and publishes version-matched
WASM modules, graph definitions, and an OCI Helm chart to the repository's GHCR
namespace. Release tags are immutable. Version `1.0.0-rc.3` adds the five
reading patterns and an optional clock publisher. Map and Filter run as
separate components.

Pushes and pull requests run validation. A maintainer publishes a new version
with the workflow's `workflow_dispatch` inputs (`version` and `publish=true`).
Don't reuse a published version for another source revision.

The chart requires an existing Azure IoT Operations installation with the
DataflowGraph, DataflowProfile, and RegistryEndpoint CRDs, and an existing MQTT
endpoint. It doesn't deploy a broker or change equipment.

```bash
helm upgrade --install factory-patterns \
  oci://ghcr.io/azure-samples/explore-iot-operations/helm/dataflow-patterns \
  --version 1.0.0-rc.3 \
  --namespace azure-iot-operations \
  --set endpointRef=default
```

Use the endpoint name configured for your broker instead of `default` if needed.
Each installation gets a separate topic prefix. Don't install competing
instances on the same asset/topic set. The graph artifact and module versions
must match the chart's `artifactVersion`.

### Use complete standalone manifests

For an existing `default` profile and `factory-mqtt` endpoint in
`azure-iot-operations`, the sample includes separate, complete manifests:

- [`align-by-time.yaml`](dataflow-patterns/manifests/align-by-time.yaml)
- [`correlate-predictions.yaml`](dataflow-patterns/manifests/correlate-predictions.yaml)
- [`report-by-exception.yaml`](dataflow-patterns/manifests/report-by-exception.yaml)
- [`stable-alarm.yaml`](dataflow-patterns/manifests/stable-alarm.yaml)
- [`offline-detection.yaml`](dataflow-patterns/manifests/offline-detection.yaml)
- [`running-total.yaml`](dataflow-patterns/manifests/running-total.yaml)
- [`smooth-readings.yaml`](dataflow-patterns/manifests/smooth-readings.yaml)

From the repository root, apply the registry endpoint and the example you need:

```bash
kubectl apply -f samples/wasm/dataflow-patterns/manifests/registry.yaml
kubectl apply -f samples/wasm/dataflow-patterns/manifests/correlate-predictions.yaml
```

For timestamp alignment, apply `align-by-time.yaml` instead. The
[`fixtures`](dataflow-patterns/fixtures/) and
[`contracts.json`](dataflow-patterns/contracts.json) describe the input messages.
Use either these standalone manifests or the Helm installation for a given
topic set, so multiple graphs don't process the same messages.

### Supply clock events during sensor silence

The change-reporting, alarm, and availability graphs evaluate elapsed time when
an input arrives. Enable the optional clock publisher to keep those checks
running while sensors are quiet. It publishes ticks for the configured assets
and periodically registers expected assets for availability checks.

Set `ticker.enabled=true`, list the assets in `ticker.assets`, and configure
`ticker.mqttHost` for the broker used by `endpointRef`. The default publisher uses
TLS and a projected service-account token. Set `ticker.caConfigMap` to the
existing broker CA ConfigMap when the broker uses a private certificate authority.
Its `ca.crt` entry must contain the broker's trusted CA certificate.

For example, these Helm values enable clock events for the synthetic asset used
in the walkthroughs:

```yaml
ticker:
  enabled: true
  assets: [sensor-1]
  mqttHost: YOUR_BROKER_HOST
  caConfigMap: YOUR_BROKER_CA_CONFIGMAP
  intervalSeconds: 1
```

Use your installation's host and CA names. Broker authorization must allow the
clock identity to publish the clock and registration topics, while sensor
identities publish only their reading topics. Reset publishers use their own
authorized reset topic. The processor validates the incoming MQTT topic against
the message kind before changing state.

The publisher's readiness probe requires recent successful broker
acknowledgments. Monitor both the publisher and graph health: detection latency
includes clock cadence, transport and processing delay. On a graph restart,
periodic registration restores the expected-asset watches.

### Walk through the five reading patterns

The chart and standalone manifests already contain the demonstration settings
below, including complete, exact full-topic `inputTopics` bindings. **No settings
JSON editing is needed.** Graph-artifact and Rust core defaults remain generic:
an alarm defaults to zero persistence and offline detection to ten seconds.

| Sample | Explicit deployment settings |
| --- | --- |
| Report by exception | `heartbeatIntervalMs: 1000` |
| Stable alarm | `high: 80`, `low: 70`, `raiseForMs: 1000`, `clearForMs: 500`, `maxObservationGapMs: 1500` |
| Offline detection | `timeoutMs: 1000` |
| Running total | Bootstrap `sensor-1` at total/version/epoch/sequence zero |
| Smooth readings | Default blend `alpha: 0.5` |

Use a fresh deployment with no other publishers. For standalone deployment,
apply `registry.yaml` and the five reading manifests linked above. For Helm,
use the installation command above. Set `PREFIX=factory` for standalone manifests
or `PREFIX=dataflow-patterns/factory-patterns` for that Helm release (use your
`topicPrefix` value if overridden).

The following Bash commands use installed Mosquitto MQTT clients. Configure
`MQTT_ARGS` for your broker's trusted TLS listener and required authentication;
the client identity must be authorized for these sample topics. Do not disable
certificate validation. Start the subscriber in a separate terminal using the
same variables:

```bash
PREFIX=dataflow-patterns/factory-patterns
MQTT_ARGS=(-h "$MQTT_HOST" -p 8883 --cafile "$MQTT_CA_FILE")
# Add your broker's required authentication options to MQTT_ARGS.
mosquitto_sub "${MQTT_ARGS[@]}" -q 1 -v -t "$PREFIX/#"
```

In the publishing terminal, set the same `PREFIX` and `MQTT_ARGS`, then define:

```bash
send() { mosquitto_pub "${MQTT_ARGS[@]}" -q 1 -t "$PREFIX/$1" -m "$2"; }
tick() { send "$1" "{\"kind\":\"tick\",\"assetId\":\"$2\",\"sampledAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"; }
```

Run each block once on fresh state; reusing message IDs intentionally suppresses
duplicates. Subscriber output includes both published inputs and graph outputs.

```bash
# factory-patterns: changes -> initial 10, cached heartbeat 10, change 12.
send report-readings '{"kind":"reading","assetId":"demo-report","messageId":"r1","sequence":1,"value":10}'
sleep 1.2
tick report-ticks demo-report
send report-readings '{"kind":"reading","assetId":"demo-report","messageId":"r2","sequence":2,"value":12}'

# alarms -> active after 1.2s, cleared after another 0.7s of low observation.
# The first tick stays inside the 1.5s maximum observation gap.
send alarm-readings '{"kind":"reading","assetId":"demo-alarm","messageId":"a1","sequence":1,"value":80}'
sleep 1.2
tick alarm-ticks demo-alarm
send alarm-readings '{"kind":"reading","assetId":"demo-alarm","messageId":"a2","sequence":2,"value":70}'
sleep 0.7
tick alarm-ticks demo-alarm

# availability -> offline for a registered, never-seen asset, then online/recovered.
send availability-registers '{"kind":"register","assetId":"demo-availability"}'
sleep 1.2
tick availability-ticks demo-availability
send availability-readings '{"kind":"reading","assetId":"demo-availability","messageId":"v1","sequence":1,"value":10}'

# totals -> 2.5 (version 1), reset to 0 (version 2, epoch 1), then 3 (version 3).
send total-readings '{"kind":"reading","assetId":"sensor-1","messageId":"t1","sequence":1,"epoch":0,"value":2.5}'
send total-resets '{"kind":"reset","assetId":"sensor-1","resetId":"reset-1","sequence":2,"expectedStateVersion":1}'
send total-readings '{"kind":"reading","assetId":"sensor-1","messageId":"t2","sequence":3,"epoch":1,"value":3}'

# smoothed -> 10, then 11.
send smoothing-readings '{"kind":"reading","assetId":"demo-smoothing","messageId":"s1","sequence":1,"value":10}'
send smoothing-readings '{"kind":"reading","assetId":"demo-smoothing","messageId":"s2","sequence":2,"value":12}'
```

Ticks evaluate the processing clock; their `sampledAt` does not advance it.
A heartbeat repeats a cached observation, not a new measurement. Alarm ticks
do not refresh observations: a gap over 1500ms cancels pending persistence.
If manual timing misses that limit, publish a new sequenced reading and retry.
Authorize reading, tick, registration and reset publishers separately in real
deployments; a payload's `kind` is not authorization.

For continuous clocks, the chart's optional ticker publishes only ticks and
idempotent availability registrations for configured assets. Set
`ticker.enabled=true`, `ticker.mqttHost` and `ticker.assets` using Helm values;
its default authentication uses a projected service-account token. Grant that
identity publish permission only on enabled tick/register topics. It never
publishes readings or resets. Do not run it alongside the isolated verification
below: those tests publish their own clocks and expect no other publishers.

### Verify the installed release

Use a fresh release and topic prefix: these tests intentionally update model
state. Install `paho-mqtt==2.1.0` and `PyYAML==6.0.2` in your test environment,
then point the verifier at the same broker used by the installed MQTT endpoint:

```bash
cd samples/wasm/dataflow-patterns
MQTT_HOST=<broker-host> MQTT_PORT=1883 \
  bash scripts/verify-deployed.sh <kubeconfig-file> azure-iot-operations factory-patterns
```

The verifier checks the installed resources and single-instance profile before
publishing fixtures. It also waits for the worker and all graph components to
be ready; a running pod alone doesn't establish that WASM initialization has
finished. It checks timestamp selection, delayed correlation in both
arrival orders, duplicate suppression, model activation, all five reading
patterns with the deployment timings above, and the absence of prediction output
for update-only messages. Heartbeats are expected explicitly, not ignored.
The MQTT client must be authorized
for the release's input and output topics. Use the script's TLS or authentication
environment variables when your broker requires them; don't disable broker
security to run the tests.

The optional `helm test` hook runs the packaged verifier inside the cluster.
Enable it with `tests.enabled=true` and set `tests.mqttHost` to a broker listener
reachable from the test pod. That hook doesn't carry broker credentials; for
authenticated listeners, run the external verifier with your authorized test
client instead.

### State and recovery limits

These modules maintain bounded **in-memory** state. Pending matches, duplicate
tracking, and active model updates are lost on restart. One runtime instance is
required. Keep durable approvals and update IDs in an external supervisor;
bootstrap the latest approved model before allowing readings after a restart.
The demonstration predictor starts `line-1` at model `v7`; that isn't a recovery
mechanism for a deployed application.

The timestamp aligner has no background timer. Publish trusted periodic
`tick` messages for each asset to release idle tails and expire old state.
Consumers must support `{"kind":"batch","records":[...]}` outputs. See
`contracts.json` rather than assuming every input produces one output.

No module fits or approves a model, guarantees exactly-once delivery, or
actuates equipment. The examples demonstrate data processing, not a safety
controller.

## Python operators

Python samples and instructions now live in [`samples/wasm-python`](../wasm-python/README.md). The VS Code extension can also build Python operators when that workspace is opened.

## Notes

- Operator names should avoid hyphens or underscores to satisfy current extension constraints.
- Use the provided `graph.dataflow.yaml` for a ready-to-run graph; other YAMLs provide additional scenarios.
- Sample inputs live under `data-and-images/`; extension runs write outputs to `data-and-images/output`.

## Links

- Data Flow Graphs overview: https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-dataflow-graph-wasm
- WASM development guide: https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-develop-wasm-modules