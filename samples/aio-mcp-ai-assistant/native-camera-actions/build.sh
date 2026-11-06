#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/native-camera-actions"
cargo fmt --all -- --check
cargo test --locked --target-dir "$ROOT/.build/camera-target"
cargo clippy --locked --all-targets --target-dir "$ROOT/.build/camera-target" -- -D warnings
for stage in get-status continuous-move stop; do
    cargo build --locked --release --target wasm32-wasip2 --features "$stage" \
        --target-dir "$ROOT/.build/camera-target"
    cp "$ROOT/.build/camera-target/wasm32-wasip2/release/edge_camera_actions.wasm" \
        "$ROOT/.build/camera-$stage.wasm"
done
printf 'Built three independent camera-action WASM components in %s/.build\n' "$ROOT"
