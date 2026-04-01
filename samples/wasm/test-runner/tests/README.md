# WASM DataFlow Test Runner Tests

This directory contains automated tests for the CLI test runner (`aio-dataflow test`).
Each subdirectory is a self-contained test case with a `.test.yaml` descriptor,
input data, and expected output. All paths are relative so the entire `wasm/`
directory can be copied as a portable unit.

## Test Overview

| Test | Scenario | Graph | Input | Description |
|------|----------|-------|-------|-------------|
| t01-simple-temp-conversion | Simple | graph-simple.yaml | 1209°F | Basic F→C map transform |
| t02-complex-temp-pipeline | Complex | graph-complex.yaml | 1209°F | Full pipeline: branch → map → filter → accumulate → enrichment |
| t03-complex-full-pipeline | Complex | graph.dataflow.yaml | 3083°F + humidity 85 + bear.raw | End-to-end: temperature + humidity + wasi-nn ML inference |
| t04-opc-ua-basic-flatten | OPC UA | graph-opc-ua.yaml | 2 OPC UA tags | Standard DataValue flattening |
| t05-opc-ua-missing-fields | OPC UA | graph-opc-ua.yaml | Mixed valid/invalid tags | Missing Value/Timestamp handling |
| t06-opc-ua-multi-tag | OPC UA | graph-opc-ua.yaml | 3 OPC UA tags | Multi-tag flattening |
| t08-schema-valid | Schema | schema-registry-scenario | `{humidity:175, temperature:12.5}` | Valid payload passes through |
| t09-schema-invalid | Schema | schema-registry-scenario | `{humidity:175.1}` (float) | Invalid payload filtered out |
| t10-schema-mixed | Schema | schema-registry-scenario | 3 payloads (1 valid) | Mixed valid/invalid filtering |
| t11-statestore-enrichment | StateStore | statestore-scenario | 360°F | State store key-value lookup as MQTT user properties |

> **Note:** OTel transform scenarios are not currently supported and have been excluded.

## Prerequisites

Before running tests, you must:
1. Pull and tag the required Docker images (see Bug Bash instructions)
2. Start the development environment: `aio-dataflow run start`
3. Build WASM operators for each scenario used by the tests

### Build Commands

```bash
# Main operators (t01–t06)
aio-dataflow build --app /path/to/wasm

# Schema operators (t08–t10)
aio-dataflow build --app /path/to/wasm/schema-registry-scenario

# StateStore operators (t11)
aio-dataflow build --app /path/to/wasm/statestore-scenario
```

## Running Tests

```bash
# From the wasm/ directory:
cd /path/to/wasm

# Run all tests
aio-dataflow test --app . test-runner/tests

# Run a single test
aio-dataflow test --app . test-runner/tests/t01-simple-temp-conversion

# Run tests matching a pattern
aio-dataflow test --app . test-runner/tests --filter "opc"
```

## Test YAML Format

```yaml
name: "Human-readable test name"
graph: "relative/path/to/graph.dataflow.yaml"
input: "relative/path/to/input/directory"
expected: "./expected/expected.json"
timeout: 90000
select: ["payload"]           # JSON paths to keep for comparison
ignores:                       # JSON paths to exclude (optional)
  - "payload.someField"
```

### Comparison Rules

- **Single object** in `expected.json` → compared against the last output message
- **Array** in `expected.json` → element-by-element comparison (order-sensitive)
- **Empty array `[]`** → asserts zero output messages received

### Input File Conventions

- `.json` files → published to `probe/1` MQTT topic
- `.raw` files → published to `snapshot_simulation` MQTT topic
- Files are published near-simultaneously (no ordering guarantee)

## Directory Structure

```
test-runner/tests/
├── README.md
├── t01-simple-temp-conversion/
│   ├── t01-simple-temp-conversion.test.yaml
│   ├── input/temperature_payload.json
│   └── expected/expected.json
├── t02-complex-temp-pipeline/
│   ├── t02-complex-temp-pipeline.test.yaml
│   ├── input/temperature_payload.json
│   └── expected/expected.json
├── t03-complex-full-pipeline/
│   ├── t03-complex-full-pipeline.test.yaml
│   ├── input/
│   │   ├── temperature_payload.json
│   │   ├── humidity_payload.json
│   │   └── bear.raw
│   └── expected/expected.json
├── t04-opc-ua-basic-flatten/
│   ├── t04-opc-ua-basic-flatten.test.yaml
│   ├── input/opc_ua_payload.json
│   └── expected/expected.json
├── t05-opc-ua-missing-fields/
│   ├── t05-opc-ua-missing-fields.test.yaml
│   ├── input/opc_ua_mixed.json
│   └── expected/expected.json
├── t06-opc-ua-multi-tag/
│   ├── t06-opc-ua-multi-tag.test.yaml
│   ├── input/opc_ua_three_tags.json
│   └── expected/expected.json
├── t08-schema-valid/
│   ├── t08-schema-valid.test.yaml
│   ├── input/valid_payload.json
│   └── expected/expected.json
├── t09-schema-invalid/
│   ├── t09-schema-invalid.test.yaml
│   ├── input/invalid_payload.json
│   └── expected/expected.json
├── t10-schema-mixed/
│   ├── t10-schema-mixed.test.yaml       (input → schema-registry-scenario/data)
│   └── expected/expected.json
└── t11-statestore-enrichment/
    ├── t11-statestore-enrichment.test.yaml (input → statestore-scenario/data)
    └── expected/expected.json
```
