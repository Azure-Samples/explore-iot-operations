ARG RUST_VERSION=1.87
FROM rust:${RUST_VERSION}-alpine

ARG ARCH="x86_64"

RUN apk add --no-cache clang lld musl-dev git perl make cmake
RUN rustup target add wasm32-wasip2 ${ARCH}-unknown-linux-gnu

# Set up environment for Cargo registry
ENV CARGO_REGISTRIES_AZURE_WASM_SDK_INDEX="sparse+https://pkgs.dev.azure.com/azure-iot-sdks/iot-operations/_packaging/preview/Cargo/index/"
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

WORKDIR /src
