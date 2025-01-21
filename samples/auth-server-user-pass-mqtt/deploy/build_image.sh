#!/bin/bash

set -e

if [ -z "$IMAGE_TAG" ]; then
    echo "Set IMAGE_TAG before running"
    exit 1
fi

src=$(readlink -m "$0/../..")

docker run --rm -it \
    -e RUSTFLAGS="-C target-feature=-crt-static" \
    -v "$src:/src" \
    -w /src \
    rust:alpine \
    sh -c "apk update; apk add musl-dev openssl-dev pkgconfig; cargo build --target x86_64-unknown-linux-musl --release"

mkdir -p "$src/image"
rm -rf "$src/image/*"
cp "$src/Dockerfile" image/
cp "$src/target/x86_64-unknown-linux-musl/release/auth-server-user-pass-mqtt" image/
strip image/auth-server-user-pass-mqtt

docker build -t "$IMAGE_TAG" -f "$src/image/Dockerfile" "$src/image/"
docker push "$IMAGE_TAG"
rm -rf "$src/image"