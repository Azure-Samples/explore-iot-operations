# Rust WASM Operators

This directory contains WebAssembly (WASM) operator projects implemented in Rust. Each operator demonstrates best practices for different operator types and data processing patterns and is wired for the VS Code extension layout (operators live beside the graph YAML files).

## Quick Start

To build any operator in this folder:

```bash
# Navigate to an operator directory
cd temperature/

# Build with the streamlined Docker builder
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name temperature

# Output will be in: bin/x86_64/release/temperature.wasm
```

## Operator Categories

### Data Processing Operators

#### collection - Data Aggregation
- Path: `collection/`
- Operator Type: Accumulate
- Purpose: Aggregate sensor data from multiple sources (temperature, humidity, object detection)
- Use Cases: 
  - Multi-sensor data fusion
  - Creating composite sensor readings
  - Building data summaries for analytics
- Key Features: Handles different data types, configurable time windows

#### enrichment - Data Enhancement  
- Path: `enrichment/`
- Operator Type: Map
- Purpose: Enhance temperature data with threshold flags and metadata
- Use Cases:
  - Adding computed fields to existing data
  - Flagging out-of-range values
  - Data quality indicators
- Key Features: Configuration-driven thresholds, preserves original data

#### format - Data Transformation
- Path: `format/`
- Operator Type: Map  
- Purpose: Decode and rescale snapshot images for object detection processing
- Use Cases:
  - Image preprocessing pipelines
  - Format conversion between systems
  - Data normalization
- Key Features: Image processing, memory-efficient transformations

### Sensor-Specific Processors

#### temperature - Temperature Processing Suite
- Path: `temperature/`
- Multiple Operators: Map, Branch, Filter, Accumulate
- Purpose: Comprehensive temperature data processing
- Operators:
  - Map: Convert Fahrenheit ↔ Celsius with configurable precision
  - Branch: Route data based on sensor type (temperature vs humidity)  
  - Filter: Remove readings outside configurable thresholds
  - Accumulate: Time-windowed aggregation with statistical summaries
- Use Cases: HVAC systems, environmental monitoring, industrial processes

#### humidity - Humidity Data Processing
- Path: `humidity/`
- Operator Type: Accumulate
- Purpose: Process and aggregate humidity sensor readings
- Use Cases:
  - Environmental monitoring
  - Climate control systems
  - Data quality assurance
- Key Features: Configurable time windows, statistical aggregation

#### snapshot - Image/Video Processing
- Path: `snapshot/`
- Multiple Operators: Branch, Map, Accumulate
- Purpose: Process visual data for object detection workflows
- Operators:
  - Branch: Route visual vs non-visual data streams
  - Map: Extract highest-confidence object detection results
  - Accumulate: Batch process multiple frames within time windows
- Use Cases: Computer vision pipelines, surveillance systems, quality control

### Timing and Flow Control

#### window - Time-Based Processing
- Path: `window/`
- Operator Type: Delay
- Purpose: Control data timing and implement windowing strategies
- Use Cases:
  - Real-time data buffering
  - Event ordering and synchronization
  - Time-based data processing
- Key Features: Configurable delay intervals, preserves data ordering

### Azure AI Video Indexer insights processing

#### viconverter - insights conversion processing
- Path: `viconverter/`
- Operator Type: Map
- Purpose: transform and flatten video indexer insights to specific format that can be further processed and stored by Azure Event Hub and Fabric Lakehouse.
- Use Cases:
  - Computer vision pipelines
  - Image processing
  - surveillance systems

## Architecture Patterns

### Operator Type Implementations

Each operator demonstrates different patterns:

- Map Operators: 1:1 data transformations with state preservation
- Filter Operators: Conditional data passing with configurable predicates  
- Branch Operators: Multi-path routing with dynamic decision logic
- Accumulate Operators: Time-windowed aggregation with configurable functions
- Delay Operators: Temporal control with ordering guarantees

### Configuration Patterns

Operators show various configuration approaches:

```rust
// Parameter-driven configuration
fn init(config: ModuleConfiguration) -> bool {
    let threshold = config.get_parameter("temperature_threshold")
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(25.0);
    // ...
}

// Feature flag configuration  
if config.has_feature("enable_celsius_conversion") {
    // Optional functionality
}

// Multi-parameter validation
let required_params = ["min_temp", "max_temp", "unit"];
for param in required_params {
    if !config.has_parameter(param) {
        return false; // Fail initialization
    }
}
```

## Usage in Data Flow Graphs

These operators can be referenced in graph YAML configurations:

```yaml
metadata:
  name: "Simple graph"
  description: "A graph that transforms temperature from Fahrenheit to Celsius"
  version: "1.0.0"
  $schema: "https://www.schemastore.org/aio-wasm-graph-config-1.0.0.json"
  vendor: "Microsoft"

moduleRequirements:
  apiVersion: "1.1.0"
  runtimeVersion: "1.1.0"

operations:
  - operationType: "map"
    name: "temp-converter"
    module: "temperature:1.0.0"  # References temperature example
    
  - operationType: "filter" 
    name: "temp-filter"
    module: "temperature:1.0.0"

moduleConfigurations:
  - name: temp-converter
    parameters:
      target_unit:
        name: celsius
        required: true
      precision:
        name: "2"
        required: false
```

## Development Guidelines

### Building Operators

Each operator includes:
- Cargo.toml: Dependency configuration with SDK version
- src/lib.rs: Operator implementation with proper error handling  
- README.md: Specific usage instructions and configuration options

### Testing Operators

```bash
# Build in debug mode for testing
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name temperature --build-mode debug

# Validate WASM output
file bin/x86_64/release/temperature.wasm
# Should output: WebAssembly (wasm) binary module
```

### Performance Characteristics

| Example | Binary Size | Processing Latency | Memory Usage |
|---------|-------------|-------------------|--------------|
| temperature/map | ~1.6MB | <1ms | <10KB |  
| snapshot/map | ~2.1MB | 5-15ms | 50-200KB |
| collection/accumulate | ~1.8MB | 1-3ms | 20-100KB |
| format/map | ~2.3MB | 10-50ms | 100-500KB |

*Note: Measurements on typical x86_64 systems with release builds*

## Related Documentation

- [Main WASM Guide](../README.md): Complete development guide
- [Rust Development Patterns](../README.md#operator-development-patterns): Rust-specific patterns
- [Graph Configuration](../../README.md#graph-definition): Using operators in graphs
- [WIT Interfaces](../../README.md#data-model-and-wit-interfaces): Interface specifications
