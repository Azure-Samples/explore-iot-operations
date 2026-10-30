#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:?Usage: ./publish.sh CONFIG.json}"
CONFIG="$(realpath "$CONFIG")"
python "$ROOT/render.py" "$CONFIG"
REGISTRY="$(jq -er '.registry' "$CONFIG")"
VERSION="$(jq -er '.artifactVersion' "$CONFIG")"
REPOSITORY="$REGISTRY/azure-samples/edge-predictive-inference"

for stage in preprocess postprocess; do
    test -s "$ROOT/.build/$stage.wasm" || { echo "Run ./build.sh first" >&2; exit 1; }
done
python "$ROOT/models/prepare.py" --check

cd "$ROOT/.build"
for stage in preprocess postprocess; do
    oras push "$REPOSITORY/$stage:$VERSION" --image-spec v1.0 \
        --artifact-type application/vnd.module.wasm.content.layer.v1+wasm \
        "$stage.wasm:application/wasm"
done
cd "$ROOT/.generated"
for stage in preprocess postprocess; do
    oras push "$REPOSITORY/$stage-graph:$VERSION" --image-spec v1.0 \
        --artifact-type application/vnd.microsoft.aio.graph.v1+yaml \
        "$stage-graph.yaml:application/yaml"
done
cd "$ROOT/.assets/model"
oras push "$REPOSITORY/yolox-nano:$VERSION" --image-spec v1.0 \
    --artifact-type application/vnd.microsoft.foundry.model.v1 \
    model.onnx:application/octet-stream LICENSE-YOLOX:text/plain provenance.json:application/json
