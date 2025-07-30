# Python WASM Builder Runtime Environment
FROM python:3.11-slim

# Install system dependencies for building WASM modules
RUN apt-get update && apt-get install -y clang lld musl-dev git perl make cmake && \
    rm -rf /var/lib/apt/lists/*

# Install componentize-py - specific version 0.14
RUN pip install "componentize-py==0.14"

# Copy the schema to a standard location in the container
COPY schema/ /schema/

# Copy inject_pdb.py for debug builds
COPY inject_pdb.py /tools/inject_pdb.py

# Create directories
RUN mkdir -p /tools /workspace /workspace/bin

# Set the working directory
WORKDIR /workspace

# Copy the build script
COPY <<'EOF' /tools/build.sh
#!/bin/bash
set -e

# Default values
ARCH="x86_64"
BUILD_MODE="release"
APP_NAME=""
APP_TYPE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-name)
            APP_NAME="$2"
            shift 2
            ;;
        --app-type)
            APP_TYPE="$2"
            shift 2
            ;;
        --build-mode)
            BUILD_MODE="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: docker run --rm -v \"\$(pwd):/workspace\" python-wasm-builder [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --app-name NAME     Name of the application (default: directory name)"
            echo "  --app-type TYPE     Type of application: map, filter, etc. (required)"
            echo "  --build-mode MODE   Build mode: release or debug (default: release)"
            echo "  --arch ARCH         Target architecture (default: x86_64)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Examples:"
            echo "  docker run --rm -v \"\$(pwd):/workspace\" python-wasm-builder --app-name my-app --app-type map --build-mode release"
            echo "  docker run --rm -v \"\$(pwd):/workspace\" python-wasm-builder --app-name filter-app --app-type filter --build-mode debug"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Set default app name if not provided
if [ -z "$APP_NAME" ]; then
    APP_NAME=$(basename "$(pwd)")
fi

# Validate required parameters
if [ -z "$APP_TYPE" ]; then
    echo "Error: --app-type is required. Specify the type of application (map, filter, etc.)"
    echo "Use --help for usage information"
    exit 1
fi

echo "Building Python WASM module: $APP_NAME (type: $APP_TYPE, mode: $BUILD_MODE, arch: $ARCH)"

# Clean up any existing bindings
rm -rf "${APP_TYPE}_impl"

# Generate WIT bindings
echo "Generating WIT bindings..."
componentize-py -d /schema/ -w "${APP_TYPE}-impl" bindings /workspace/

# Create output directory
mkdir -p "/workspace/bin/$ARCH/$BUILD_MODE"

# Build the WASM module
echo "Building WASM component..."
if [ "$BUILD_MODE" = "release" ]; then
    componentize-py -d /schema/ -w "${APP_TYPE}-impl" componentize "${APP_TYPE}" -o "/workspace/bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
elif [ "$BUILD_MODE" = "debug" ]; then
    python /tools/inject_pdb.py "${APP_TYPE}.py"
    componentize-py -d /schema/ -w "${APP_TYPE}-impl" componentize "${APP_TYPE}_debug" -o "/workspace/bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
    cp "${APP_TYPE}_debug.py" "/workspace/bin/$ARCH/$BUILD_MODE/${APP_NAME}_debug.py"
else
    echo "Invalid BUILD_MODE: $BUILD_MODE. Use 'release' or 'debug'."
    exit 1
fi

echo "Build complete! Output: bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
EOF

RUN chmod +x /tools/build.sh

# Set the entrypoint to the build script
ENTRYPOINT ["/tools/build.sh"]
