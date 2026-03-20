# WASM DataFlow Test Runner Tests

This directory contains automated tests for the CLI test runner (`aio-dataflow test`).
Each subdirectory is a self-contained test case with a `.test.yaml` descriptor,
input data, and expected output.

## Test Overview

| Test | Scenario | Graph | Data Source |
|------|----------|-------|-------------|
| t01-simple-temp-conversion | Simple | graph-simple.yaml | `/wasm/data` |
| t02-complex-temp-pipeline | Complex | graph-complex.yaml | `/wasm/data` |
| t03-complex-full-pipeline | Complex | graph.dataflow.yaml | `/wasm/data-and-images` |
| t04-opc-ua-basic-flatten | OPC UA | graph-opc-ua.yaml | custom input |
| t05-opc-ua-missing-fields | OPC UA | graph-opc-ua.yaml | custom input |
| t06-opc-ua-multi-tag | OPC UA | graph-opc-ua.yaml | custom input |
| t07-otel-transform | OTel | graph-otel-transform.yaml | custom input |
| t08-schema-valid | Schema | schema-registry-scenario | custom input |
| t09-schema-invalid | Schema | schema-registry-scenario | custom input |
| t10-schema-mixed | Schema | schema-registry-scenario | `/wasm/schema-registry-scenario/data` |
| t11-statestore-enrichment | StateStore | statestore-scenario | `/wasm/statestore-scenario/data` |

## Data Directories

- **`/wasm/data`** — Temperature-only payloads (1209°F, 400°F, 3083°F)
- **`/wasm/data-and-images`** — Temperature + humidity + raw image files for ML inference

## Running Tests

```bash
# Run all tests
aio-dataflow test --app ../../

# Run a specific test
aio-dataflow test --app ../../ --test t01-simple-temp-conversion
```

## Test YAML Format

```yaml
name: "Human-readable test name"
graph: "relative/path/to/graph.dataflow.yaml"
input: "relative/path/to/input/directory"
expected: "./expected/expected.json"
timeout: 90000
select: ["payload"]           # JSON paths to compare
ignores:                       # JSON paths to exclude (optional)
  - "payload.someField"
```

- **Single object** in `expected.json` → compared against the last output message
- **Array** in `expected.json` → compared element-by-element against all outputs
- **Empty array `[]`** → asserts zero output messages
