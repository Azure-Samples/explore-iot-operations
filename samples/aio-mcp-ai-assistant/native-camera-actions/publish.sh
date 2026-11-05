#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$(realpath "${1:?Usage: bash native-camera-actions/publish.sh CONFIG.json}")"
python "$ROOT/manage.py" render "$CONFIG"
REGISTRY="$(python -c '
from pathlib import Path
import sys
from aio_mcp_ai_assistant.config import load_settings
graphs = load_settings(Path(sys.argv[1])).camera_graphs
if graphs is None:
    raise SystemExit("Configure cameraGraphs before publishing camera-control WASM artifacts")
print(graphs.registry)
' "$CONFIG")"
VERSION="$(python -c 'from pathlib import Path; import sys; from aio_mcp_ai_assistant.config import load_settings; s=load_settings(Path(sys.argv[1])); print(s.camera_graphs.artifact_version)' "$CONFIG")"
REPOSITORY="$REGISTRY/azure-samples/aio-mcp-ai-assistant/camera-actions"
for stage in get-status continuous-move stop; do
    test -s "$ROOT/.build/camera-$stage.wasm" || { echo "Build camera actions first" >&2; exit 1; }
done
cd "$ROOT/.build"
for stage in get-status continuous-move stop; do
    oras push "$REPOSITORY/$stage:$VERSION" --image-spec v1.0 \
        --artifact-type application/vnd.module.wasm.content.layer.v1+wasm \
        "camera-$stage.wasm:application/wasm"
done
cd "$ROOT/.generated"
for stage in get-status continuous-move stop; do
    oras push "$REPOSITORY/$stage-graph:$VERSION" --image-spec v1.0 \
        --artifact-type application/vnd.microsoft.aio.graph.v1+yaml \
        "camera-$stage-graph.yaml:application/yaml"
done
