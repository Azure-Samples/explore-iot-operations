# Azure IoT Operations WASM samples for Rust

This workspace is structured for the Azure IoT Operations VS Code extension so the `operators/` folder and graph YAML files sit side by side. Use it to build and run WASM operators locally before deploying them.

## Layout

- `operators/` – Rust operator source
- `graph.dataflow.yaml` – default graph for the extension (copy of the complex sample)
- `graph-complex.yaml`, `graph-otel.yaml`, `graph-otel-transform.yaml`, `graph-simple.yaml` – additional graphs
- `data/`, `data-and-images/`, `images/` – sample inputs; extension runs write output to `data-and-images/output`
- `schema-registry-scenario/`, `statestore-scenario/` – scenario source code YAMLs for schema registry and state store usage
- `Dockerfile`, `Makefile`, `.cargo/` – Rust builder assets co-located here (see **Rust builds**)
- [`../wasm-python`](../wasm-python/README.md) – Python operator workspace; see its README for language-specific guidance

## Quick start with the VS Code extension

1. Install VS Code plus the Azure IoT Operations data flow extension (v0.4.13 or later) and ensure Docker is running. The RedHat YAML extension is optional but helpful.
2. Open `samples/wasm` in VS Code.
3. Build operators: `Ctrl+Shift+P` → **Azure IoT Operations: Build All Data Flow Operators** → choose **release**. The extension builds every project under `operators/`.
4. Run the sample graph: `Ctrl+Shift+P` → **Azure IoT Operations: Run Application Graph** → pick **release** → select `graph.dataflow.yaml` → choose the `data-and-images` folder when prompted for input. Logs and output land under `data-and-images/output`.
5. Explore other graphs by choosing a different YAML in step 4 (for example `graph-otel.yaml` or `graph-simple.yaml`).

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
  fn transform_data(timestamp: HybridLogicalClock, input: DataModel) -> DataModel {
      logger::log(Level::Info, "my-operator", "Processing data");
      input
  }
  ```
- Filter operator pattern:
  ```rust
  use wasm_graph_sdk::macros::filter_operator;

  #[filter_operator]
  fn temperature_filter(_ts: HybridLogicalClock, input: DataModel) -> bool {
      matches!(input, DataModel::Temperature(temp) if temp.value > 0.0)
  }
  ```
- More operators live in `operators/` (temperature, humidity, format, snapshot, collection, enrichment, window, viconverter) for fuller examples and configuration patterns.

## Python operators

Python samples and instructions now live in [`samples/wasm-python`](../wasm-python/README.md). The VS Code extension can also build Python operators when that workspace is opened.

## Notes

- Operator names should avoid hyphens or underscores to satisfy current extension constraints.
- Use the provided `graph.dataflow.yaml` for a ready-to-run graph; other YAMLs provide additional scenarios.
- Sample inputs live under `data-and-images/`; extension runs write outputs to `data-and-images/output`.

## Links

- Data Flow Graphs overview: https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-dataflow-graph-wasm
- WASM development guide: https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-develop-wasm-modules