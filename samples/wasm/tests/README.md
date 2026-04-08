# Bug Bash Plan: WASM DataFlow Test Runner (March 2026)

## Goal

Validate the **Azure IoT Operations WASM DataFlow** CLI test runner across
**five scenarios** — simple transforms, complex multi-sensor pipelines,
OPC UA flattening, JSON schema validation, and state store enrichment —
using **10 pre-built test cases** that exercise the full build → test workflow.

All tests live under `samples/wasm/tests/` and reference shared
operators and graph definitions via relative paths. The entire `wasm/` directory
is self-contained and portable. Tests work identically from the **CLI** and the
**VS Code extension** (Test Explorer auto-discovers `tests/` when `wasm/` is
opened as a workspace).

**Official documentation:**
https://learn.microsoft.com/en-us/azure/iot-operations/develop-edge-apps/howto-build-wasm-modules-vscode

---

## Prerequisites

### Software

- **Node.js** >= 20
- **Docker** running
- **VS Code** (optional, for extension testing) with:
  - [Azure IoT Operations Data Flow extension](https://marketplace.visualstudio.com/items?itemName=ms-azureiotoperations.azure-iot-operations-data-flow-vscode) (v0.4.13+)

### Docker Images

Pull and tag the required container images:

```bash
docker pull mcr.microsoft.com/azureiotoperations/processor-app:1.1.5
docker tag mcr.microsoft.com/azureiotoperations/processor-app:1.1.5 host-app

docker pull mcr.microsoft.com/azureiotoperations/devx-runtime:0.1.8
docker tag mcr.microsoft.com/azureiotoperations/devx-runtime:0.1.8 devx

docker pull mcr.microsoft.com/azureiotoperations/statestore-cli:0.0.2
docker tag mcr.microsoft.com/azureiotoperations/statestore-cli:0.0.2 statestore-cli

docker pull eclipse-mosquitto
```

### Install the CLI

```bash
npm install -g @azure-tools/dataflow-dev
```

Or run directly via Node.js:
```bash
node /path/to/cli.js <command>
```

---

## Quick Start (Run Everything)

```bash
cd samples/wasm

# 1. Start the development environment
dataflow-dev run start

# 2. Build all operators
dataflow-dev build --app .
dataflow-dev build --app ./schema-registry-scenario
dataflow-dev build --app ./statestore-scenario

# 3. Run all 10 tests
dataflow-dev test --app .

# 4. Stop when done
dataflow-dev run stop
```

**Expected result:** `Results: 10 passed, 0 failed, 0 errored (10 total)`

---

## Scenarios & Tests

### Scenario 1: Simple — Temperature F→C Conversion

A single `map` operator converts temperature from Fahrenheit to Celsius.

```
source → temperature/map (F→C) → sink
```

| Test | Input | Expected Output | What It Validates |
|------|-------|-----------------|-------------------|
| **t01-simple-temp-conversion** | 1209°F | 653.89°C | Basic F→C map transform |

**Run individually:**
```bash
dataflow-dev test --app . tests/t01-simple-temp-conversion
```

---

### Scenario 2: Complex — Multi-Sensor Pipeline

7 operators process temperature, humidity, and snapshot image data through
branching, filtering, accumulation, ML inference, and enrichment.

```
source → window/delay → snapshot/branch
  ├─ True  → format/map → snapshot/map (ML) → snapshot/accumulate
  └─ False → temperature/branch
               ├─ True  → temperature/map → temperature/filter → temperature/accumulate
               └─ False → humidity/accumulate
All → concatenate → collection/accumulate → enrichment/map → sink
```

| Test | Input | Expected Output | What It Validates |
|------|-------|-----------------|-------------------|
| **t02-complex-temp-pipeline** | 1209°F | temp accumulation (count=1, 653.89°C, overtemp=true) | Branch → map → filter → accumulate → enrichment |
| **t03-complex-full-pipeline** | 3083°F + humidity 85 + bear.raw | temp + humidity + object detection ("American black bear") | End-to-end: all branches, wasi-nn ML, convergence |

**Run individually:**
```bash
dataflow-dev test --app . tests/t02-complex-temp-pipeline
dataflow-dev test --app . tests/t03-complex-full-pipeline
```

> **Note:** t03 uses the `graph.dataflow.yaml` (with wasi-nn feature) while t02 uses
> `graph-complex.yaml` (without wasi-nn). t03 takes ~25s due to the ML inference step.

---

### Scenario 3: OPC UA — Telemetry Flattening

A single `map` operator transforms OPC UA `{Tag: {Value, SourceTimestamp}}`
objects into flat `[{tag, value, timestamp}]` arrays suitable for database ingestion.

```
source → opc-ua/map (flatten) → sink
```

| Test | Input | Expected Output | What It Validates |
|------|-------|-----------------|-------------------|
| **t04-opc-ua-basic-flatten** | Temperature + Pressure tags | 2 flat rows | Standard DataValue flattening |
| **t05-opc-ua-missing-fields** | GoodTag + MissingValue + MissingTimestamp + NotAnObject | Only GoodTag row | Edge case handling |
| **t06-opc-ua-multi-tag** | MotorSpeed + Vibration + AmbientTemp | 3 flat rows (alphabetical) | Multi-tag processing |

**Run individually:**
```bash
dataflow-dev test --app . tests/t04-opc-ua-basic-flatten
```

---

### Scenario 4: Schema — JSON Schema Validation

A `filter` operator validates incoming payloads against a JSON schema
(`tk_schema_config.json`). Messages that don't conform are silently dropped.

**Schema rules:** `humidity` must be an integer, `temperature` must be a number.

```
source → filter (schema validation) → sink
```

> **Important:** Build schema operators first: `dataflow-dev build --app ./schema-registry-scenario`

| Test | Input | Expected Output | What It Validates |
|------|-------|-----------------|-------------------|
| **t08-schema-valid** | `{humidity:175, temperature:12.5}` | Passes through | Valid data accepted |
| **t09-schema-invalid** | `{humidity:175.1, temperature:12}` | `[]` (filtered) | Float humidity rejected |
| **t10-schema-mixed** | 3 payloads from schema-registry-scenario/data | Only the valid payload | Mixed filtering |

**Run individually:**
```bash
dataflow-dev test --app . tests/t08-schema-valid
```

---

### Scenario 5: StateStore — State Store Enrichment

The `otel-enrich` operator reads `factoryId` and `machineId` from the
distributed state store and injects them as MQTT user properties. The payload
passes through unchanged.

```
source → otel-enrich/map → sink
```

> **Important:** Build statestore operators first: `dataflow-dev build --app ./statestore-scenario`

| Test | Input | Expected Output | What It Validates |
|------|-------|-----------------|-------------------|
| **t11-statestore-enrichment** | 360°F temp | Payload unchanged + `otel/factoryId=factoryA`, `otel/machineId=machineA` | State store key lookup, MQTT user properties |

**Run individually:**
```bash
dataflow-dev test --app . tests/t11-statestore-enrichment
```

---

## Step-by-Step Bug Bash Workflow

### Step 1: Start the Development Environment

```bash
cd samples/wasm
dataflow-dev run start
```

This starts the DevX container. It stays running across all scenarios.

---

### Step 2: Build All Operators

Three separate build commands are needed because operators live in different directories:

```bash
# Main operators (temperature, humidity, collection, enrichment, format,
# snapshot, window, opc-ua, viconverter)
dataflow-dev build --app .

# Schema filter operator
dataflow-dev build --app ./schema-registry-scenario

# StateStore otel-enrich operator
dataflow-dev build --app ./statestore-scenario
```

---

### Step 3: Run All Tests

```bash
dataflow-dev test --app .
```

**Expected:** `Results: 10 passed, 0 failed, 0 errored (10 total)`

If any test fails, run it individually to see detailed output:
```bash
dataflow-dev test --app . tests/t03-complex-full-pipeline
```

---

### Step 4: Explore & Experiment

| What to Try | How |
|------------|-----|
| **Run a subset of tests** | `dataflow-dev test --app . --filter "opc"` |
| **Modify an operator** | Edit `operators/<name>/src/lib.rs`, rebuild with `dataflow-dev build --app .` |
| **Add a new test case** | Copy a test folder, modify `input/` and `expected/`, add a `.test.yaml` |
| **Inspect MQTT traffic** | `docker exec devx mosquitto_sub -t '+/#' -v` |
| **View container logs** | `docker logs -f devx` or check `<test>/output/` after a run |
| **Change state store values** | Edit `statestore-scenario/statestore.json`, rebuild, re-run |
| **Try different images** | Replace `bear.raw` in t03 input with any image from `images/` |

---

### Step 5: Stop the Development Environment

```bash
dataflow-dev run stop
```

---

## Test Summary (10 tests)

| Scenario | Tests | Operators | Features Covered |
|----------|-------|-----------|-----------------|
| Simple | 1 | temperature | map, F→C conversion |
| Complex | 2 | window, format, snapshot, temperature, humidity, collection, enrichment | branch, map, filter, accumulate, delay, concatenate, wasi-nn ML, state store enrichment |
| OPC UA | 3 | opc-ua | DataValue flattening, missing field handling, multi-tag |
| Schema | 3 | filter | JSON schema validation, integer/number type checking, mixed filtering |
| StateStore | 1 | otel-enrich | State store key lookup, MQTT user property injection |
| **Total** | **10** | | |

---

## How `.test.yaml` Works

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | — | Human-readable test name |
| `graph` | string | Yes | — | Path to graph YAML (relative to test file) |
| `input` | string | Yes | — | Path to input data directory (relative) |
| `expected` | string | Yes | — | Path to expected output `.json` (relative) |
| `timeout` | number | No | `60000` | Timeout in milliseconds |
| `select` | string[] | No | `[]` | JSON dot-paths to keep for comparison |
| `ignores` | string[] | No | `[]` | JSON dot-paths to exclude from comparison |

### Input Conventions

- `.json` files → published to `probe/1` MQTT topic
- `.raw` files → published to `snapshot_simulation` MQTT topic
- Files are published near-simultaneously (no ordering guarantee)

### Expected Output

- **Single object** → compared against the last output message
- **Array** → order-sensitive element-by-element comparison
- **Empty `[]`** → asserts zero messages received (these tests take ~30s due to polling timeout)

---

## Known Issues & Troubleshooting

1. **Empty-output tests are slow** — Tests expecting `[]` (like t09) wait ~30s due to internal polling timeout. This is expected.

2. **State store persists across tests** — The enrichment operator's overtemp flag persists in state store. If running tests individually in different orders, the `overtemp` value may differ. Run `dataflow-dev run stop && dataflow-dev run start` to reset state.

3. **Image files must be `.raw`** — The publisher only recognizes `.json` and `.raw` extensions. Rename images accordingly.

4. **OPC UA tag ordering** — The flattened output assumes alphabetical tag ordering. If the runtime produces a different order, update the expected file.

5. **Build before test** — All three build commands must succeed before running the full test suite. Missing WASM modules cause "ERROR: No WASM modules found" errors.

6. **OTel transform excluded** — The `otel-transform` operator has a known bug (panics on line 190 when `metricValuePath` is not configured). OTel tests are excluded from this test runner.

---

## Generating Expected Output

If a test fails and you need to update the expected output:

1. Run the failing test and check the "Actual" output in the console
2. Copy the payload from the actual output
3. Update `expected/expected.json` with the correct values
4. Re-run to confirm it passes

Alternatively, run the graph manually:
```bash
dataflow-dev run graph --app . --graph graph-simple.yaml --data tests/t01-simple-temp-conversion/input
```

Inspect output in `input/output/<timestamp>.txt`, extract the relevant JSON, and save to `expected/expected.json`.

---

## Directory Structure

```
samples/wasm/
├── graph-simple.yaml            ← Simple: source → temp/map → sink
├── graph-complex.yaml           ← Complex pipeline (no wasi-nn)
├── graph.dataflow.yaml          ← Complex pipeline (with wasi-nn)
├── graph-opc-ua.yaml            ← OPC UA: source → opc-ua/map → sink
├── operators/                   ← All shared WASM operator source
│   ├── temperature/
│   ├── humidity/
│   ├── collection/
│   ├── enrichment/
│   ├── format/
│   ├── snapshot/
│   ├── window/
│   ├── opc-ua/
│   └── ...
├── schema-registry-scenario/    ← Schema validation scenario
│   ├── graph.dataflow.yaml
│   ├── tk_schema_config.json
│   ├── data/
│   └── operators/filter/
├── statestore-scenario/         ← State store enrichment scenario
│   ├── graph.dataflow.yaml
│   ├── statestore.json
│   ├── data/
│   └── operators/otel-enrich/
├── images/                      ← 22 raw image files for ML inference
├── data/                        ← Temperature-only payloads
├── data-and-images/             ← Temperature + humidity + image payloads
└── tests/                       ← All 10 test cases (auto-discovered by CLI & extension)
    ├── README.md
    ├── t01-simple-temp-conversion/
    ├── t02-complex-temp-pipeline/
    ├── t03-complex-full-pipeline/
    ├── t04-opc-ua-basic-flatten/
    ├── t05-opc-ua-missing-fields/
    ├── t06-opc-ua-multi-tag/
    ├── t08-schema-valid/
    ├── t09-schema-invalid/
    ├── t10-schema-mixed/
    └── t11-statestore-enrichment/
```
