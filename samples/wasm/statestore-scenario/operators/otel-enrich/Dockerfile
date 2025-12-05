ARG IMAGE=aio-wasm-graph-wasm-rust-build
FROM $IMAGE AS operator-build

ARG APP_NAME
ARG BUILD_MODE="release"

ENV CARGO_REGISTRIES_AIO_WG_INDEX="sparse+https://pkgs.dev.azure.com/azure-iot-sdks/iot-operations/_packaging/preview/Cargo/index/"
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

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
COPY --from=operator-build "/src/target/wasm32-wasip2/${BUILD_MODE}/${APP_NAME/-/_}.wasm" "${APP_NAME//_/-}.wasm"
ENTRYPOINT [ "${APP_NAME}.wasm" ]
