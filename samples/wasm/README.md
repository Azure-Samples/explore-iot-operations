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

The [`dataflow-patterns/`](dataflow-patterns/) sample provides three custom Rust
graphs. They complement the built-in transforms; they don't require sliding
windows.

| Graph | Input | Operation | Output |
| --- | --- | --- | --- |
| `graph-align-by-time` | Separate speed and temperature messages, plus ticks | Select the latest eligible temperature at or before each speed timestamp | An aligned record, or a batch when several readings become ready |
| `graph-correlate-by-id` | Predictions and delayed measurements | Buffer either arrival order and match asset, piece, and optional run IDs | A completed match with prediction residual and target error |
| `graph-versioned-predictor` | Readings and externally approved model updates | Activate only the expected next version; evaluate readings with the active model | Predictions only; update acknowledgments don't re-enter the data path |

### Build and exercise the operators

Use the public SDK registry configured in `samples/wasm/.cargo/config.toml`.
Install Rust with the `wasm32-wasip2` target, then run:

```bash
cd samples/wasm/dataflow-patterns
make test check build
cargo run --locked --example replay -- fixtures/align-by-time.json
cargo run --locked --example replay -- fixtures/correlate-by-id.json
cargo run --locked --example replay -- fixtures/versioned-predictor.json
```

The fixtures contain input messages and expected results. [`contracts.json`](dataflow-patterns/contracts.json)
defines the exact fields, configurable bounds, counters, batch envelopes, and
restart requirements. Native fixture replay isn't a substitute for deployment
testing against an Azure IoT Operations runtime.

### Deploy the matching release

The GitHub workflow [Dataflow pattern WASM samples](../../.github/workflows/dataflow-patterns.yml)
builds the locked Rust sources, tests the chart, and publishes version-matched
WASM modules, graph definitions, and an OCI Helm chart to the repository's GHCR
namespace. Release tags are immutable. The initial sample candidate is
`1.0.0-rc.2`, not a production-support commitment. Version `1.0.0-rc.1`
failed AIO 1.6 initialization and must not be used. The corrected release
uses separate Map and Filter components.

The chart requires an existing Azure IoT Operations installation with the
DataflowGraph, DataflowProfile, and RegistryEndpoint CRDs, and an existing MQTT
endpoint. It doesn't deploy a broker or change equipment.

```bash
helm upgrade --install factory-patterns \
  oci://ghcr.io/azure-samples/explore-iot-operations/helm/dataflow-patterns \
  --version 1.0.0-rc.2 \
  --namespace azure-iot-operations \
  --set endpointRef=default
```

Use the endpoint name configured for your broker instead of `default` if needed.
Each installation gets a separate topic prefix. Don't install competing
instances on the same asset/topic set. The graph artifact and module versions
must match the chart's `artifactVersion`.

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
publishing fixtures. It checks timestamp selection, delayed correlation in both
arrival orders, duplicate suppression, model activation, and the absence of
prediction output for update-only messages. The MQTT client must be authorized
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