# WASM Rust Build Base Image

This Docker image provides a base environment for building WebAssembly (WASM) applications with Rust targeting the `wasm32-wasip2` platform.

## Features

- Based on Alpine Linux with Rust 1.85
- Pre-configured for WASM compilation with `wasm32-wasip2` target
- Required build tools: clang, lld, musl-dev, git, perl, make, cmake
- Environment variables for Azure IoT Operations Cargo registry

## Usage

This base image is intended to be used as a build stage in multi-stage Docker builds for WASM operators:

```dockerfile
ARG IMAGE=ghcr.io/azure-samples/explore-iot-operations/wasm-rust-build:latest
FROM $IMAGE AS operator-build

ARG APP_NAME
ARG BUILD_MODE="release"

WORKDIR /src
COPY ./Cargo.toml ./Cargo.toml
COPY ./src ./src

RUN if [ "${BUILD_MODE}" = "release" ]; then \
        cargo build --release --target wasm32-wasip2; \
    else \
        cargo build --target wasm32-wasip2; \
    fi

FROM scratch
ARG BUILD_MODE
ARG APP_NAME
COPY --from=operator-build "/src/target/wasm32-wasip2/${BUILD_MODE}/${APP_NAME}.wasm" "${APP_NAME}.wasm"
ENTRYPOINT [ "${APP_NAME}.wasm" ]
```

## Build Arguments

- `RUST_VERSION`: Rust version to use (default: 1.85)
- `ARCH`: Target architecture (default: x86_64)

## Environment Variables

- `CARGO_REGISTRIES_AZURE_VSCODE_TINYKUBE_INDEX`: Azure IoT Operations Cargo registry URL
- `CARGO_NET_GIT_FETCH_WITH_CLI`: Use Git CLI for fetching dependencies

## Publishing

This image is automatically built and published to GitHub Container Registry via GitHub Actions when changes are made to the `docker/wasm-rust-build/` directory.
