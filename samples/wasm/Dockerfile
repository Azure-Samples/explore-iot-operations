# Rust WASM Builder Runtime Environment
ARG RUST_VERSION=1.87
FROM rust:${RUST_VERSION}-alpine

ARG ARCH="x86_64"

# Install build dependencies
RUN apk add --no-cache clang lld musl-dev git perl make cmake
RUN rustup target add wasm32-wasip2 ${ARCH}-unknown-linux-gnu

# Set up cargo registry for Azure IoT Operations packages
ENV CARGO_REGISTRIES_AIO_WG_INDEX="sparse+https://pkgs.dev.azure.com/azure-iot-sdks/iot-operations/_packaging/preview/Cargo/index/"
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

# Create directories
RUN mkdir -p /tools /workspace /workspace/bin

# Set the working directory
WORKDIR /workspace

# Copy the build script
COPY <<'EOF' /tools/build.sh
#!/bin/sh
set -e

# Default values
ARCH="x86_64"
BUILD_MODE="release"
APP_NAME=""

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
        --app-name)
            APP_NAME="$2"
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
            echo "Usage: docker run --rm -v \"\$(pwd):/workspace\" rust-wasm-builder [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --app-name NAME     Name of the application (default: directory name)"
            echo "  --build-mode MODE   Build mode: release or debug (default: release)"
            echo "  --arch ARCH         Target architecture (default: x86_64)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Examples:"
            echo "  docker run --rm -v \"\$(pwd):/workspace\" rust-wasm-builder --app-name my-app --build-mode release"
            echo "  docker run --rm -v \"\$(pwd):/workspace\" rust-wasm-builder --app-name format --build-mode debug"
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

echo "Building Rust WASM module: $APP_NAME (mode: $BUILD_MODE, arch: $ARCH)"

# Create output directory
mkdir -p "/workspace/bin/$ARCH/$BUILD_MODE"

# Build the WASM module
echo "Building WASM component..."
if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --target wasm32-wasip2
    cp "/workspace/target/wasm32-wasip2/release/${APP_NAME}.wasm" "/workspace/bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
else
    cargo build --target wasm32-wasip2
    cp "/workspace/target/wasm32-wasip2/debug/${APP_NAME}.wasm" "/workspace/bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
fi

echo "Build complete! Output: bin/$ARCH/$BUILD_MODE/${APP_NAME}.wasm"
EOF

RUN chmod +x /tools/build.sh

# Set the entrypoint to the build script
ENTRYPOINT ["/tools/build.sh"]
