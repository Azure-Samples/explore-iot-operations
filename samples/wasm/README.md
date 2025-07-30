# Azure IoT Operations Data Flow Graphs: WASM Development Guide

This guide shows you how to develop WebAssembly (WASM) modules for Azure IoT Operations data flow graphs. Data flow graphs are a public preview feature that enables real-time data processing through configurable pipelines using **Rust** or **Python**.

## Overview

Azure IoT Operations data flow graphs process streaming data in real-time through pipelines of configurable operators. Each operator runs as a WebAssembly (WASM) module that processes timestamped data using the Timely dataflow execution model.

### Key benefits

- **Real-time processing**: Handle streaming data with consistent low latency
- **Configurable pipelines**: Compose custom data processing workflows without code changes
- **Event-time semantics**: Process data based on when events occurred, not when they're processed
- **Fault tolerance**: Built-in support for handling failures and ensuring data consistency
- **Scalability**: Distribute processing across multiple nodes while maintaining order guarantees
- **Multi-language support**: Develop in Rust or Python

## Understanding the Architecture

### From academic research to production

Azure IoT Operations data flow graphs build on solid academic research and production-proven systems:

1. **Academic foundation**: The system builds on research from Microsoft Research's Naiad project, which introduced the concept of timely dataflow for distributed computation.

2. **Timely dataflow**: The [Timely dataflow system](https://docs.rs/timely/latest/timely/dataflow/operators/index.html) provides the computational model where:
   - Data items have logical timestamps
   - Operations process data while maintaining temporal ordering
   - The system can reason about progress and completion

3. **WASM modules**: User-defined logic runs as WebAssembly modules, providing:
   - Language independence (Rust and Python supported)
   - Sandboxed execution
   - Portable, efficient code

### Key terminology: Operators vs. modules

Understanding the distinction between operators and modules is important for developing with data flow graphs:

#### **Operators**
Operators are the fundamental building blocks of data processing pipelines based on [Timely dataflow operators](https://docs.rs/timely/latest/timely/dataflow/operators/index.html). Each operator processes timestamped data while maintaining temporal ordering:

- **[Map](https://docs.rs/timely/latest/timely/dataflow/operators/map/trait.Map.html)**: Transform each data item (like converting temperature units)
- **[Filter](https://docs.rs/timely/latest/timely/dataflow/operators/filter/trait.Filter.html)**: Allow only certain data items to pass through based on predicates (like removing invalid readings)
- **[Branch](https://docs.rs/timely/latest/timely/dataflow/operators/branch/trait.Branch.html)**: Route data to different paths based on conditions (like separating temperature vs. humidity data)
- **[Accumulate](https://docs.rs/timely/latest/timely/dataflow/operators/count/trait.Accumulate.html)**: Collect and aggregate data within timestamps (like computing statistical summaries)
- **[Concatenate](https://docs.rs/timely/latest/timely/dataflow/operators/core/concat/trait.Concatenate.html)**: Merge multiple data streams while preserving temporal order
- **[Delay](https://docs.rs/timely/latest/timely/dataflow/operators/delay/trait.Delay.html)**: Advance timestamps using supplied functions to control timing
- **Source**: Generate or receive data from external systems (MQTT, sensors, files)
- **Sink**: Output processed data to external systems (databases, MQTT, files)

#### **WebAssembly Interface Types (WIT)**
All operators implement standardized interfaces defined using [WebAssembly Interface Types (WIT)](https://github.com/WebAssembly/component-model/blob/main/design/mvp/WIT.md). WIT provides language-agnostic interface definitions that ensure compatibility between WASM modules and the host runtime, regardless of whether you're writing in Rust or Python.

To see the complete data model and WIT interface definitions for each operator type, see the [Data Model and WIT Interfaces](#data-model-and-wit-interfaces) reference section.

#### **Modules** 
Modules are the **implementation** of operator logic as WASM code:

- A single module can implement multiple operator types
- For example, a `temperature` module might provide:
  - A **map** operator for unit conversion
  - A **filter** operator for threshold checking  
  - A **branch** operator for routing decisions
  - An **accumulate** operator for aggregation

#### **The relationship**
```
Graph Definition → References Module → Provides Operator → Processes Data
     ↓                    ↓               ↓              ↓
"temperature:1.0.0" → temperature.wasm → map function → °F to °C
```

### Why timely dataflow?

Traditional stream processing systems face challenges with:
- **Out-of-order data**: Events arriving later than expected
- **Partial results**: Not knowing when computations are complete
- **Coordination**: Synchronizing distributed processing

Timely dataflow solves these problems through:

#### **Timestamps and progress tracking**
Every data item carries a timestamp representing its logical time. The system tracks progress through these timestamps, enabling:
- **Deterministic processing**: Same input always produces same output
- **Exactly-once semantics**: No duplicate or missed processing
- **Watermarks**: Knowing when no more data will arrive for a given time

#### **Hybrid logical clock**
The timestamp mechanism uses a hybrid approach:
```rust
pub struct HybridLogicalClock {
    pub physical_time: u64,  // Wall-clock time when event occurred
    pub logical_time: u64,   // Logical ordering for events at same physical time
}
```

This ensures:
- **Causal ordering**: Effects follow causes
- **Progress guarantees**: System knows when processing is complete
- **Distributed coordination**: Multiple nodes stay synchronized


## Rust Development

### Prerequisites
- **Rust**: Install Rust toolchain with `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`
- Add WASM target: `rustup target add wasm32-wasip2`
- **Build tools**: `cargo install wasm-tools --version '=1.201.0' --locked`

For comprehensive documentation of the WASM Rust SDK including APIs for state store, metrics, and logging, see the [WASM Rust SDK Reference](#wasm-rust-sdk-reference).

### Create your operator project
```bash
cargo new --lib temperature-converter
cd temperature-converter
```

### Configure Cargo.toml
```toml
[package]
name = "temperature-converter"
version = "0.1.0"
edition = "2021"

[dependencies]
tinykube_wasm_sdk = { version = "0.2.0", registry = "azure-vscode-tinykube" }
serde = { version = "1", default-features = false, features = ["derive"] }
serde_json = { version = "1", default-features = false, features = ["alloc"] }

[lib]
crate-type = ["cdylib"]
```

### Implement your operator
```rust
// src/lib.rs
use tinykube_wasm_sdk::logger::{self, Level};
use tinykube_wasm_sdk::macros::map_operator;
use serde_json::{json, Value};

fn temperature_converter_init(configuration: ModuleConfiguration) -> bool {
    logger::log(Level::Info, "temperature-converter", "Init invoked");
    true
}

#[map_operator(init = "temperature_converter_init")]
fn temperature_converter(input: DataModel) -> DataModel {
    let DataModel::Message(mut result) = input else {
        return input;
    };

    let payload = &result.payload.read();
    if let Ok(data_str) = std::str::from_utf8(payload) {
        if let Ok(mut data) = serde_json::from_str::<Value>(data_str) {
            if let Some(temp) = data["value"]["temperature"].as_f64() {
                let fahrenheit = (temp * 9.0 / 5.0) + 32.0;
                data["value"] = json!({
                    "temperature_fahrenheit": fahrenheit,
                    "original_celsius": temp
                });
                
                if let Ok(output_str) = serde_json::to_string(&data) {
                    result.payload.write(output_str.as_bytes());
                }
            }
        }
    }

    DataModel::Message(result)
}
```

### Implementing operators
For comprehensive examples of map, filter, branch, accumulate, and delay operators, see:
- **Rust examples**: Navigate to `rust/examples/` for complete implementations
- **Timely operators**: [Timely dataflow documentation](https://docs.rs/timely/latest/timely/dataflow/operators/index.html)

### Build your module
```bash
# Build WASM module
cargo build --release --target wasm32-wasip2

# Find your module
ls target/wasm32-wasip2/release/*.wasm
file target/wasm32-wasip2/release/temperature_converter.wasm
```

#### Alternative: Docker Builder

For simplified development without local toolchain setup, use the streamlined Docker builder:

```bash
# Build release version (default)
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name temperature-converter

# Build debug version with symbols  
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name temperature-converter --build-mode debug
```

Output will be placed in `bin/<ARCH>/<BUILD_MODE>/temperature-converter.wasm`. For complete Docker builder documentation, see the [Rust README](rust/README.md).

## Python Development

### Prerequisites
- **Python**: Python 3.8 or later
- Install componentize-py: `pip install "componentize-py==0.14"`

### Create your operator
```python
# temperature_converter.py
import json
from map_impl import exports
from map_impl import imports
from map_impl.imports import types

class Map(exports.Map):
    def init(self, configuration) -> bool:
        imports.logger.log(imports.logger.Level.INFO, "temperature-converter", "Init invoked")
        return True

    def process(self, message: types.DataModel) -> types.DataModel:
        # Extract and decode the payload
        buffer = message.value.payload.value
        data_str = buffer.decode('utf-8')
        
        try:
            data = json.loads(data_str) 
            # Process temperature conversion logic
            if 'value' in data and 'temperature' in data['value']:
                celsius = float(data['value']['temperature'])
                fahrenheit = (celsius * 9/5) + 32
                
                output = {
                    'value': {
                        'temperature_fahrenheit': fahrenheit,
                        'original_celsius': celsius
                    }
                }
                
                output_str = json.dumps(output)
                output_bytes = output_str.encode('utf-8')
                
                return types.DataModel_Message(
                    content_type=message.value.content_type,
                    payload=types.DataModel_MessagePayload_Bytes(output_bytes)
                )
            
            return message  # Pass through if no temperature found
            
        except Exception as e:
            imports.logger.log(imports.logger.Level.ERROR, "temperature-converter", f"Error: {e}")
            return message
```

### Build your module
```bash
# Generate Python bindings from schema
componentize-py -d python/operators/schema/ -w map-impl bindings ./

# Build WASM module
componentize-py -d python/operators/schema/ -w map-impl componentize temperature_converter -o temperature_converter.wasm

# Verify build
file temperature_converter.wasm  # Should show: WebAssembly (wasm) binary module
```

#### Alternative: Docker Builder

For simplified development without local toolchain setup, use the streamlined Docker builder:

```bash
# Build release version (requires --app-type for Python)
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name temperature-converter --app-type map

# Build debug version with symbols
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name temperature-converter --app-type map --build-mode debug
```

Output will be placed in `bin/<ARCH>/<BUILD_MODE>/temperature-converter.wasm`. For complete Docker builder documentation, see the [Python README](python/README.md).

### Implementing operators

For examples, see the comprehensive operator implementations in `python/examples/` which demonstrate:
- **Map operators**: Data transformation and conversion logic
- **Filter operators**: Conditional data processing and validation
- **Branch operators**: Multi-path routing based on data content
- **Accumulate operators**: Time-windowed aggregation and statistical processing

## Graph Definition

Data flow graphs define how WASM operators connect and process data streams using YAML configuration files. The graph definition and WASM modules are uploaded together to OCI registries, allowing Azure IoT Operations to locate modules by examining the same registry where the graph definition resides.

### Schema and structure

Graph definitions follow a formal [JSON schema](ConfigGraph.json) that validates structure and ensures compatibility. The configuration includes:

1. **Module requirements**: API and host library version compatibility
2. **Module configurations**: Runtime parameters for operator customization
3. **Operations**: Processing nodes in your pipeline
4. **Connections**: Data flow routing between operations
5. **Schemas** (optional): Data validation schemas

### Version compatibility

The `moduleRequirements` section ensures compatibility using semantic versioning:

```yaml
moduleRequirements:
  apiVersion: "0.2.0"          # WASI API version for interface compatibility
  hostlibVersion: "0.2.0"     # Host library version providing runtime support
  features:                    # Optional features required by modules
    - name: "wasi-nn"
```

<!-- TODO: Expand versioning documentation when flexible semver support is added to AIO data flow graphs -->

### Complete examples

For working examples, see:
- **Simple pipeline**: [graph-simple.yaml](graph-simple.yaml) - Basic source → map → sink flow
- **Complex processing**: [graph-complex.yaml](graph-complex.yaml) - Multi-operator pipeline with branching and aggregation

### Basic structure
```yaml
moduleRequirements:
  apiVersion: "0.2.0"
  hostlibVersion: "0.2.0"

operations:
  - operationType: "source"
    name: "data-source"
  - operationType: "map"
    name: "my-operator/map"
    module: "my-operator:1.0.0"
  - operationType: "sink"
    name: "data-sink"

connections:
  - from: { name: "data-source" }
    to: { name: "my-operator/map" }
  - from: { name: "my-operator/map" }
    to: { name: "data-sink" }
```

## Module Configuration Parameters

Module configurations define runtime parameters that your WASM operators can access. These parameters allow you to customize operator behavior without rebuilding the module.

### Parameter structure
```yaml
moduleConfigurations:
  - name: my-operator/map
    parameters:
      threshold:
        name: temperature_threshold
        description: "Temperature threshold for filtering"
        required: true
      unit:
        name: output_unit
        description: "Output temperature unit"
        required: false
```

### Consuming parameters in code

Parameters are accessed through the `ModuleConfiguration` struct passed to your operator's `init` function:

#### Python example
```python
def temperature_converter_init(configuration):
    # Access configuration parameters
    threshold = configuration.get_parameter("temperature_threshold")
    unit = configuration.get_parameter("output_unit", default="celsius")
    
    imports.logger.log(imports.logger.Level.INFO, "temperature-converter", 
                      f"Initialized with threshold={threshold}, unit={unit}")
    return True
```

#### Rust example (see `rust/examples/branch/`)
```rust
fn branch_init(configuration: ModuleConfiguration) -> bool {
    // Access required parameters
    if let Some(threshold_param) = configuration.parameters.get("temperature_threshold") {
        let threshold: f64 = threshold_param.parse().unwrap_or(25.0);
        logger::log(Level::Info, "branch", &format!("Using threshold: {}", threshold));
    }
    
    // Access optional parameters with defaults
    let unit = configuration.parameters
        .get("output_unit")
        .map(|s| s.as_str())
        .unwrap_or("celsius");
    
    true
}
```

For a complete implementation example, see the branch module in `rust/examples/branch/` which demonstrates parameter usage for conditional routing logic.

## Graph Definition

Data flow graphs define how WASM operators connect and process data streams using YAML configuration files. The graph definition and WASM modules are uploaded together to OCI registries, allowing Azure IoT Operations to locate modules by examining the same registry where the graph definition resides.

## Data Model and WIT Interfaces

All WASM operators, whether implemented in Rust or Python, work with standardized interfaces and data models defined using WebAssembly Interface Types (WIT). WIT provides language-agnostic interface definitions that ensure compatibility between WASM modules and the host runtime.

### Data Model

All operators work with a flexible union type `data-model` that supports various data formats:

```wit
// Core timestamp structure using hybrid logical clock
record timestamp {
    timestamp: timespec,     // Physical time (seconds + nanoseconds)
    node-id: buffer-or-string,  // Logical node identifier
}

// Union type supporting multiple data formats
variant data-model {
    buffer-or-bytes(buffer-or-bytes),    // Raw byte data
    message(message),                    // Structured messages with metadata
    snapshot(snapshot),                  // Video/image frames with timestamps
}

// Structured message format
record message {
    timestamp: timestamp,
    content_type: buffer-or-string,
    payload: message-payload,
}
```

### WIT Interface Definitions

Each operator type implements a specific WIT interface that defines its function signature:

```wit
// Core operator interfaces
interface map {
    use types.{data-model};
    process: func(message: data-model) -> data-model;
}

interface filter {
    use types.{data-model};
    process: func(message: data-model) -> bool;
}

interface branch {
    use types.{data-model, hybrid-logical-clock};
    process: func(timestamp: hybrid-logical-clock, message: data-model) -> bool;
}

interface accumulate {
    use types.{data-model};
    process: func(staged: data-model, message: list<data-model>) -> data-model;
}
```

These interfaces are used by:
- **Python**: Generated bindings provide typed access to these interfaces
- **Rust**: The WASM Rust SDK provides procedural macros that implement these interfaces automatically

## WASM Rust SDK Reference

The WASM Rust SDK provides a comprehensive development framework specifically for Rust developers creating WASM modules. Python developers work directly with generated bindings from the WIT interfaces above.

### Operator Macros

The Rust SDK provides procedural macros to simplify operator development:

```rust
use tinykube_wasm_sdk::macros::{map_operator, filter_operator, branch_operator};

// Map operator - transforms each data item
#[map_operator(init = "my_init_function")]
fn my_map(input: DataModel) -> DataModel {
    // Transform logic here
}

// Filter operator - allows/rejects data based on predicate  
#[filter_operator(init = "my_init_function")]
fn my_filter(input: DataModel) -> bool {
    // Return true to pass data through, false to filter out
}

// Branch operator - routes data to different arms
#[branch_operator(init = "my_init_function")]
fn my_branch(input: DataModel, timestamp: HybridLogicalClock) -> bool {
    // Return true for "True" arm, false for "False" arm
}
```

### Host APIs

The SDK provides access to host functionality:

#### State Store Client
Distributed key-value storage for persistent data:

```rust
use tinykube_wasm_sdk::state_store;

// Set value
state_store::set(key.as_bytes(), value.as_bytes(), None, None, options)?;

// Get value  
let response = state_store::get(key.as_bytes(), None)?;

// Delete key
state_store::del(key.as_bytes(), None, None)?;
```

#### Logging
Structured logging with different levels:

```rust
use tinykube_wasm_sdk::logger::{self, Level};

logger::log(Level::Info, "my-operator", "Processing started");
logger::log(Level::Error, "my-operator", &format!("Error: {}", error));
```

#### Metrics
OpenTelemetry-compatible metrics:

```rust
use tinykube_wasm_sdk::metrics;

// Increment counter
metrics::add_to_counter("requests_total", 1.0, Some(labels))?;

// Record histogram value
metrics::record_to_histogram("processing_duration", duration_ms, Some(labels))?;
```

### Architecture Integration

The WASM Rust SDK integrates with the cloud-native architecture:

- **Timely dataflow execution**: All operators run within the Timely computational model
- **Container isolation**: WASM modules execute in sandboxed environments  
- **Resource management**: Built-in support for memory and CPU limits
- **Distributed processing**: Seamless scaling across multiple nodes
- **Fault tolerance**: Automatic recovery and state management

For detailed API documentation and examples, refer to the SDK source code and the comprehensive operator examples in `rust/examples/`.