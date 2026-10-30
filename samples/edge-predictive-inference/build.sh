#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT/wasm"
cargo fmt --all -- --check
cargo test --locked --target-dir "$ROOT/.build/target"
for stage in preprocess postprocess; do
    cargo build --locked --release --target wasm32-wasip2 \
        --features "$stage" --target-dir "$ROOT/.build/target"
    cp "$ROOT/.build/target/wasm32-wasip2/release/edge_predictive_inference.wasm" \
        "$ROOT/.build/$stage.wasm"
done
cargo build --locked --release --example pipeline --target-dir "$ROOT/.build/target"
printf 'Built both WASM components and the native model-validation helper in %s/.build\n' "$ROOT"
