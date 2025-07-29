ARG RUST_VERSION=1.85
FROM rust:${RUST_VERSION}-alpine

ARG ARCH="x86_64"

RUN apk add --no-cache clang lld musl-dev git perl make cmake
RUN rustup target add wasm32-wasip2 ${ARCH}-unknown-linux-gnu
