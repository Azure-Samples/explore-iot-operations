# Python WASM Operators (VS Code extension ready)

This guide shows how to build and run Python-based WASM operators for Azure IoT Operations. The folder follows the VS Code extension layout: operators live under `operators/`, and builds drop artifacts into each operator’s `bin/` directory.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Development Environment Setup](#development-environment-setup)
- [Build Options](#build-options)
- [Python Operator Development](#python-operator-development)
- [Building Python WASM Operators](#building-python-wasm-operators)
- [Available Operator Templates](#available-operator-templates)
- [Examples](#examples)
- [Best Practices](#best-practices)

## Overview

Python WASM operators provide an alternative to Rust for implementing data flow graph operators. While Rust offers maximum performance, Python provides:

- **Rapid development**: Familiar syntax and extensive libraries
- **Easy debugging**: Built-in debugging support with `pdb`
- **Flexible data processing**: Rich ecosystem for data manipulation
- **Prototyping**: Quick iteration for proof-of-concept implementations

### Key Differences from Rust

- **No SDK**: Python operators use exported function interfaces directly
- **Runtime performance**: Generally slower than Rust but easier to develop
- **Component model**: Uses `componentize-py` instead of direct WASM compilation
- **Debugging**: Native Python debugging tools available

## Prerequisites

### Required Tools

1. **Python 3.11+**:
   ```bash
   python3 --version  # Should be 3.11 or higher
   ```

2. **componentize-py**:
   ```bash
   pip install "componentize-py==0.14"
   ```

3. **Docker** (for containerized builds):
   ```bash
   docker --version
   ```

4. **Development dependencies**:
   ```bash
   # These are included in the base Docker image
   # For local development:
   apt-get install clang lld musl-dev git perl make cmake
   ```

## Development Environment Setup

### Option 1: Using Docker (Recommended)

The project provides a pre-built Python builder image:

```bash
# The builder image is available at:
ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder:latest
```

### Option 2: Local Setup

For local development without Docker:

```bash
# Install Python and pip
python3 -m pip install --upgrade pip

# Install componentize-py
pip install "componentize-py==0.14"

# Install system dependencies (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y clang lld musl-dev git perl make cmake
```

## Build Options

You can build operators three ways:
- **VS Code extension (recommended):** Open `samples/wasm-python` → `Ctrl+Shift+P` → **Azure IoT Operations: Build All Data Flow Operators** → pick **release** or **debug**. Output: `operators/<name>/bin/<arch>/<mode>/`.
- **Docker builder:** Use the published builder image (see [Building Python WASM Operators](#building-python-wasm-operators)). Run it from an operator directory; output goes to that operator’s `bin/` folder.
- **Local componentize-py:** Install prerequisites and run `componentize-py` directly (see [Build WASM Component](#build-wasm-component)).

To run any module you need a graph YAML that references the built operator (for example `graph.dataflow.yaml`). Keep the graph file alongside the operators when running locally or with the extension.

## Python Operator Development

Operators live under `operators/`. The sections below cover the interfaces and workflow.

### Understanding the Interface

Python operators implement specific interfaces defined by the WebAssembly Interface Types (WIT). Unlike Rust, Python doesn't have a high-level SDK, so you work directly with the exported function interfaces.

### Operator Interface Structure

Each operator type has a corresponding interface:

1. **Export Interface**: Functions you must implement
2. **Import Interface**: Functions provided by the host system

### Development Workflow

1. **Generate Bindings**: Create Python bindings for your operator type
2. **Implement Logic**: Write your custom processing logic
3. **Build WASM**: Compile to WebAssembly component
4. **Test**: Validate functionality and performance

### Step-by-Step Development

#### 1. Create Project Directory

```bash
mkdir my-python-operator
cd my-python-operator
```

#### 2. Generate Bindings

Choose your operator type and generate bindings. For example, using a `map` operator:

```bash
# Generate bindings for map operator
componentize-py -d ./schema/ -w map-impl bindings ./
```

This creates a directory structure:
```
my-python-operator/
├── map_impl/
│   ├── __init__.py
│   ├── exports/
│   │   ├── __init__.py
│   │   └── map.py
│   ├── imports/
│   │   ├── __init__.py
│   │   ├── hybrid_logical_clock.py
│   │   ├── logger.py
│   │   ├── metrics.py
│   │   ├── state_store.py
│   │   └── types.py
│   └── types.py
```

#### 3. Implement Your Operator

Create your implementation file, e.g., `map.py`:

```python
from map_impl import exports
from map_impl import imports
from map_impl.imports import types

class Map(exports.Map):
    def init(self, configuration) -> bool:
        """
        Initialize the operator with configuration parameters.
        Called once when the operator starts.
        """
        imports.logger.log(
            imports.logger.Level.INFO, 
            "my-operator", 
            "Initializing operator"
        )
        
        # Process configuration parameters
        # configuration contains the moduleConfiguration from graph YAML
        
        return True  # Return True if initialization succeeds

    def process(self, timestamp: int, input: types.DataModel) -> types.DataModel:
        """
        Process a single data item.
        Called for each data item flowing through the operator.
        """
        imports.logger.log(
            imports.logger.Level.INFO, 
            "my-operator", 
            "Processing data item"
        )
        
        # Implement your transformation logic here
        if isinstance(input, types.DataModel_Message):
            message = input.value
            
            # Example: Extract and process payload
            if isinstance(message.payload, types.BufferOrBytes_Buffer):
                buffer = message.payload.value
                payload_bytes = buffer.read()
                payload_str = payload_bytes.decode("utf-8")
                
                # Transform the data
                transformed_payload = self.transform_data(payload_str)
                
                # Create new message with transformed payload
                new_payload = types.BufferOrBytes_Bytes(
                    transformed_payload.encode("utf-8")
                )
                
                new_message = types.Message(
                    timestamp=message.timestamp,
                    topic=message.topic,
                    payload=new_payload
                )
                
                return types.DataModel_Message(new_message)
        
        # Return input unchanged if no transformation needed
        return input
    
    def transform_data(self, data: str) -> str:
        """
        Custom transformation logic.
        Implement your specific data processing here.
        """
        # Example: Convert JSON data, apply filters, etc.
        try:
            import json
            parsed = json.loads(data)
            
            # Example transformation: add processing timestamp
            parsed["processed_at"] = time.time()
            
            return json.dumps(parsed)
        except json.JSONDecodeError:
            # Handle non-JSON data
            return data.upper()  # Simple transformation example
```

#### 4. Build WASM Component

```bash
# For release build (optimized)
componentize-py -d ./schema/ -w map-impl componentize map -o my-operator.wasm

# For debug build (with debugging support)
# First, inject debug support
python inject_pdb.py map.py

# Then build with debug mode
componentize-py -d ./schema/ -w map-impl componentize map_debug -o my-operator-debug.wasm
```

## Building Python WASM Operators

### Using the streamlined Docker builder

The recommended approach uses a single Docker command with the built-in builder:

#### Quick Start

```bash
# Build release version
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name my-operator --app-type map

# Build debug version with symbols
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name my-operator --app-type map --build-mode debug
```

#### Complete Usage

```bash
docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder [OPTIONS]

Options:
  --app-name NAME     Name of the application (default: directory name)
  --app-type TYPE     Type of application: map, filter, etc. (required)
  --build-mode MODE   Build mode: release or debug (default: release)
  --arch ARCH         Target architecture (default: x86_64)
  -h, --help          Show this help message

Examples:
  docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name my-app --app-type map --build-mode release
  docker run --rm -v "$(pwd):/workspace" ghcr.io/azure-samples/explore-iot-operations/python-wasm-builder --app-name filter-app --app-type filter --build-mode debug
```

#### Output Structure

The built `.wasm` files will be placed in the following directory structure:
```
bin/<ARCH>/<BUILD_MODE>/
├── my-operator.wasm
└── my-operator_debug.py  # (debug mode only)
```

For example:
```
bin/x86_64/release/my-operator.wasm
bin/x86_64/debug/my-operator.wasm
bin/x86_64/debug/my-operator_debug.py
```

### Build the Docker builder (one-time setup)

The recommended approach is to use the published images from GitHub Container Registry. However, if you need to build the Docker builder image locally:

```bash
cd /path/to/samples/wasm-python
docker build -t python-wasm-builder .
```

**Note:** When building locally, use the local image name (`python-wasm-builder`) instead of the full GitHub Container Registry URL in the commands above.

## Available Operator Templates

The repository includes templates for all supported operator types:

### Map Operator
- **Path**: `operators/map/`
- **Purpose**: Transform individual data items
- **Interface**: `process(timestamp, input) -> output`

### Filter Operator  
- **Path**: `operators/filter/`
- **Purpose**: Allow/reject data based on conditions
- **Interface**: `process(timestamp, input) -> bool`

### Branch Operator
- **Path**: `operators/branch/`
- **Purpose**: Route data to different output paths
- **Interface**: `process(timestamp, input) -> int`

### Accumulate Operator
- **Path**: Currently being developed
- **Purpose**: Aggregate data over time windows
- **Interface**: `process(staged, messages) -> staged`

### Delay Operator
- **Path**: Currently being developed
- **Purpose**: Control timing and ordering of data
- **Interface**: `process(data, timestamp) -> new_timestamp`

## Examples

### Temperature Data Processing

Here's a complete example of a temperature processing operator:

```python
from map_impl import exports
from map_impl import imports
from map_impl.imports import types
import json
import time

class Map(exports.Map):
    def init(self, configuration) -> bool:
        imports.logger.log(
            imports.logger.Level.INFO, 
            "temperature-processor", 
            "Initializing temperature processor"
        )
        
        # Store configuration for later use
        self.config = configuration
        self.conversion_factor = 1.0
        
        # Parse configuration parameters
        if hasattr(configuration, 'properties'):
            for key, param in configuration.properties.items():
                if key == "conversion_factor":
                    self.conversion_factor = float(param.name)
        
        return True

    def process(self, timestamp: int, input: types.DataModel) -> types.DataModel:
        try:
            if isinstance(input, types.DataModel_Message):
                message = input.value
                
                if isinstance(message.payload, types.BufferOrBytes_Buffer):
                    # Read payload data
                    buffer = message.payload.value
                    payload_bytes = buffer.read()
                    payload_str = payload_bytes.decode("utf-8")
                    
                    # Parse temperature data
                    temp_data = json.loads(payload_str)
                    
                    if "temperature" in temp_data:
                        # Convert temperature (e.g., Fahrenheit to Celsius)
                        temp_f = float(temp_data["temperature"])
                        temp_c = (temp_f - 32) * 5/9 * self.conversion_factor
                        
                        # Update the data
                        temp_data["temperature"] = round(temp_c, 2)
                        temp_data["unit"] = "celsius"
                        temp_data["processed_at"] = time.time()
                        
                        # Log the conversion
                        imports.logger.log(
                            imports.logger.Level.INFO,
                            "temperature-processor",
                            f"Converted {temp_f}°F to {temp_c}°C"
                        )
                        
                        # Create new payload
                        new_payload_str = json.dumps(temp_data)
                        new_payload = types.BufferOrBytes_Bytes(
                            new_payload_str.encode("utf-8")
                        )
                        
                        # Create new message
                        new_message = types.Message(
                            timestamp=message.timestamp,
                            topic=message.topic,
                            payload=new_payload
                        )
                        
                        return types.DataModel_Message(new_message)
            
        except Exception as e:
            imports.logger.log(
                imports.logger.Level.ERROR,
                "temperature-processor",
                f"Error processing data: {str(e)}"
            )
        
        # Return original data if processing fails
        return input
```

### Sensor Data Routing (Branch Example)

```python
from branch_impl import exports
from branch_impl import imports
from branch_impl.imports import types
import json

class Branch(exports.Branch):
    def init(self, configuration) -> bool:
        imports.logger.log(
            imports.logger.Level.INFO,
            "sensor-router",
            "Initializing sensor data router"
        )
        return True

    def process(self, timestamp: int, input: types.DataModel) -> int:
        """
        Route data based on sensor type:
        - Return 0 for temperature sensors
        - Return 1 for humidity sensors  
        - Return 2 for other sensor types
        """
        try:
            if isinstance(input, types.DataModel_Message):
                message = input.value
                
                if isinstance(message.payload, types.BufferOrBytes_Buffer):
                    buffer = message.payload.value
                    payload_bytes = buffer.read()
                    payload_str = payload_bytes.decode("utf-8")
                    
                    # Parse sensor data
                    sensor_data = json.loads(payload_str)
                    
                    # Route based on sensor type
                    sensor_type = sensor_data.get("sensor_type", "unknown")
                    
                    if sensor_type == "temperature":
                        imports.logger.log(
                            imports.logger.Level.DEBUG,
                            "sensor-router",
                            "Routing to temperature processor"
                        )
                        return 0
                    elif sensor_type == "humidity":
                        imports.logger.log(
                            imports.logger.Level.DEBUG,
                            "sensor-router", 
                            "Routing to humidity processor"
                        )
                        return 1
                    else:
                        imports.logger.log(
                            imports.logger.Level.DEBUG,
                            "sensor-router",
                            f"Routing unknown sensor type: {sensor_type}"
                        )
                        return 2
                        
        except Exception as e:
            imports.logger.log(
                imports.logger.Level.ERROR,
                "sensor-router",
                f"Error routing data: {str(e)}"
            )
        
        # Default routing for invalid data
        return 2
```

## Best Practices

### Development Guidelines

1. **Error Handling**: Always wrap processing logic in try-catch blocks
2. **Logging**: Use appropriate log levels and include context information
3. **Performance**: Minimize object creation in hot paths
4. **Memory**: Be conscious of memory usage, especially with large payloads
5. **Configuration**: Validate configuration parameters during initialization

### Debugging

Python operators support native debugging with `pdb`:

```python
# The inject_pdb.py script automatically adds debug breakpoints
# Build with DEBUG_MODE="debug" to enable debugging

def process(self, timestamp: int, input: types.DataModel) -> types.DataModel:
    import pdb; pdb.set_trace()  # Debug breakpoint
    # Your processing logic here
```

### Testing

1. **Unit Testing**: Test operator logic with mock data
2. **Integration Testing**: Use complete graph configurations
3. **Performance Testing**: Measure throughput and latency
4. **Error Testing**: Test with malformed or edge-case data

### Security Considerations

1. **Input Validation**: Always validate and sanitize input data
2. **Resource Limits**: Be mindful of memory and CPU usage
3. **Dependencies**: Keep Python dependencies minimal and updated
4. **Error Information**: Don't leak sensitive information in error messages

## Troubleshooting

### Common Build Issues

1. **Missing componentize-py**: Install with `pip install "componentize-py==0.14"`
2. **System Dependencies**: Ensure clang, lld, and other build tools are installed
3. **Python Version**: Verify you're using Python 3.11 or higher
4. **Docker Access**: Check Docker is running and you have registry access

### Runtime Issues

1. **Module Loading**: Check module name and version in graph YAML match your build
2. **Import Errors**: Verify all required Python modules are available in the WASM environment
3. **Configuration Problems**: Validate parameter names and types in moduleConfigurations
4. **Connection Errors**: Ensure graph connections reference valid operation names

### Performance Issues

1. **Large WASM Files**: Python WASM modules are typically larger than Rust (2-10MB vs 100-500KB)
2. **Slow Processing**: Profile Python code and optimize data processing loops
3. **Memory Usage**: Monitor memory consumption, especially with large payloads
4. **Debug Mode**: Disable debug mode for production builds to improve performance

### Development Issues

1. **Binding Generation**: Ensure schema files are correct and accessible
2. **Interface Mismatch**: Verify your Python class implements the required interface methods
3. **Debugging**: Use `import pdb; pdb.set_trace()` for interactive debugging in debug builds
4. **Logging**: Use the imported logger functions rather than Python's built-in logging

---

This guide provides the foundation for developing Python WASM operators for Azure IoT Operations data flow graphs. The Python approach offers rapid development and familiar debugging tools, making it ideal for prototyping and scenarios where development speed is prioritized over maximum runtime performance.
