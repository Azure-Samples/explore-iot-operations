# Rust WASM Operators Development Guide

This guide covers Rust-specific development for Azure IoT Operations data flow graph operators. For general concepts and architecture, see the [main README](../README.md).

## Overview

Rust provides the highest performance option for WASM operators with:

- **Maximum performance**: Compiled to efficient WebAssembly
- **Memory safety**: Rust's ownership system prevents common bugs
- **Rich SDK**: High-level macros and helper functions
- **Small binaries**: Optimized WASM output with minimal overhead

## Quick Start

### Prerequisites

```bash
# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env

# Add WASM target
rustup target add wasm32-wasip2
```

### Create New Operator

```bash
# Create new Rust library
cargo new --lib my-rust-operator
cd my-rust-operator

# Configure Cargo.toml for WASM
cat > Cargo.toml << EOF
[package]
name = "my-rust-operator"
version = "0.1.0"
edition = "2021"

[dependencies]
wit-bindgen = "0.22"
tinykube_wasm_sdk = { version = "0.2.0", registry="azure-vscode-tinykube" }
serde = { version = "1", default-features = false, features = ["derive"] }
serde_json = { version = "1", default-features = false, features = ["alloc"] }

[lib]
crate-type = ["cdylib"]
path = "src/lib.rs"
EOF
```

### Implement Operator

```rust
use tinykube_wasm_sdk::macros::map_operator;
use tinykube_wasm_sdk::logger::{self, Level};

#[map_operator]
fn my_operator(timestamp: HybridLogicalClock, input: DataModel) -> DataModel {
    logger::log(Level::Info, "my-operator", "Processing data");
    
    // Your transformation logic here
    input
}
```

## Available Examples

The `examples/` directory contains complete examples:

- **temperature**: Temperature data processing with multiple operator types
- **humidity**: Humidity data aggregation
- **format**: Data format conversion
- **snapshot**: Image/video processing
- **collection**: Data collection and batching
- **enrichment**: Data enrichment and annotation
- **window**: Time-based windowing operations
- **viconverter**: Azure AI Video Indexer insights conversion

## Building Operators

### Using the Streamlined Docker Builder

The recommended approach uses a single Docker command with the built-in builder:

#### Quick Start

```bash
# Build release version
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name my-operator

# Build debug version with symbols
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name my-operator --build-mode debug
```

#### Complete Usage

```bash
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder [OPTIONS]

Options:
  --app-name NAME     Name of the application (default: directory name)
  --build-mode MODE   Build mode: release or debug (default: release)
  --arch ARCH         Target architecture (default: x86_64)
  -h, --help          Show this help message

Examples:
  docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name my-app --build-mode release
  docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/rust-wasm-builder --app-name format --build-mode debug
```

#### Output Structure

The built `.wasm` files will be placed in the following directory structure:
```
bin/<ARCH>/<BUILD_MODE>/
└── my-operator.wasm
```

For example:
```
bin/x86_64/release/my-operator.wasm
bin/x86_64/debug/my-operator.wasm
```

### Build the Docker Builder (One-time Setup)

If you need to build the Docker builder image locally:

```bash
cd /path/to/samples/wasm/rust
docker build -t rust-wasm-builder .
```

## Operator Development Patterns

### Map Operator

```rust
use tinykube_wasm_sdk::macros::map_operator;
use tinykube_wasm_sdk::logger::{self, Level};

#[map_operator]
fn transform_data(timestamp: HybridLogicalClock, input: DataModel) -> DataModel {
    logger::log(Level::Info, "transform", "Processing data item");
    
    match input {
        DataModel::Temperature(mut temp) => {
            // Convert Fahrenheit to Celsius
            temp.value = (temp.value - 32.0) * 5.0 / 9.0;
            temp.unit = "celsius".to_string();
            DataModel::Temperature(temp)
        }
        _ => input, // Pass through other data types
    }
}
```

### Filter Operator

```rust
use tinykube_wasm_sdk::macros::filter_operator;

#[filter_operator]
fn temperature_filter(timestamp: HybridLogicalClock, input: DataModel) -> bool {
    match input {
        DataModel::Temperature(temp) => {
            // Filter out temperatures below freezing
            temp.value > 0.0
        }
        _ => true, // Pass through non-temperature data
    }
}
```

### Branch Operator

```rust
use tinykube_wasm_sdk::macros::branch_operator;

#[branch_operator]
fn route_by_sensor(timestamp: HybridLogicalClock, input: DataModel) -> bool {
    match input {
        DataModel::Temperature(_) => true,  // Route to branch A
        DataModel::Humidity(_) => false,    // Route to branch B
        _ => true, // Default routing
    }
}
```

## Best Practices

### Performance

- Use `cargo build --release` for production
- Minimize heap allocations in hot paths
- Prefer stack-allocated data structures
- Use `&str` instead of `String` when possible

### Error Handling

```rust
use tinykube_wasm_sdk::logger::{self, Level};

#[map_operator]
fn safe_processor(timestamp: HybridLogicalClock, input: DataModel) -> DataModel {
    match process_data(input.clone()) {
        Ok(result) => result,
        Err(e) => {
            logger::log(Level::Error, "processor", &format!("Processing failed: {}", e));
            input // Return original data on error
        }
    }
}

fn process_data(input: DataModel) -> Result<DataModel, String> {
    // Your processing logic with proper error handling
    Ok(input)
}
```

### Logging and Metrics

```rust
use tinykube_wasm_sdk::{logger, metrics};
use tinykube_wasm_sdk::logger::Level;
use tinykube_wasm_sdk::metrics::{CounterValue, Label};

#[map_operator]
fn instrumented_operator(timestamp: HybridLogicalClock, input: DataModel) -> DataModel {
    logger::log(Level::Debug, "operator", "Processing started");
    
    // Process data
    let result = transform_data(input);
    
    // Update metrics
    metrics::increment_counter("items_processed", vec![
        Label { key: "operator".to_string(), value: "my_operator".to_string() }
    ]);
    
    logger::log(Level::Debug, "operator", "Processing completed");
    result
}
```

## Troubleshooting

### Common Build Issues

1. **Missing WASM target**: 
   ```bash
   rustup target add wasm32-wasip2
   ```

2. **Registry access issues**:
   ```bash
   # Ensure you have access to the azure-vscode-tinykube registry
   # This is configured in the Docker base image
   ```

3. **Compilation errors**:
   - Check Rust version compatibility
   - Verify dependency versions in Cargo.toml
   - Ensure feature flags are correct

### Debugging

- Use `logger::log()` for runtime debugging
- Build in debug mode for detailed error information
- Use `cargo check` for faster compilation during development

### Performance Issues

- Profile with `cargo build --release`
- Minimize dependencies to reduce binary size
- Use appropriate data structures for hot paths

---

For more detailed examples and advanced patterns, see the examples in the `examples/` directory.
