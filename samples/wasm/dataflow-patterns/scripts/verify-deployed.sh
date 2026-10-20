#!/usr/bin/env bash
# No implicit current context, runtime installation, or production workflow integration.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: MQTT_HOST=host [MQTT_PORT=1883 MQTT_TLS=true] bash scripts/verify-deployed.sh KUBECONFIG NAMESPACE FRESH_RELEASE" >&2
  echo "Requires kubectl, Helm, Python, PyYAML and paho-mqtt==2.1.0. Install a fresh release into an existing qualified AIO runtime first." >&2
  exit 2
fi
config="$1"
namespace="$2"
release="$3"
[[ -f "$config" ]]
: "${MQTT_HOST:?Set the real MQTT host serving the installed endpointRef}"
scripts="$(cd -- "$(dirname -- "$0")" && pwd)"
work="$scripts/.work/deployed-$release"
if [[ ! "$release" =~ ^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$ ]]; then
  echo "Invalid Helm release name" >&2
  exit 2
fi
mkdir -p "$work"
umask 077
kubectl --kubeconfig "$config" get crd dataflowgraphs.connectivity.iotoperations.azure.com \
  dataflowprofiles.connectivity.iotoperations.azure.com \
  registryendpoints.connectivity.iotoperations.azure.com >/dev/null
helm get manifest "$release" --namespace "$namespace" --kubeconfig "$config" > "$work/manifest.yaml"
# API-server validation uses the actual installed CRDs; no substitute/fake runtime.
kubectl --kubeconfig "$config" --namespace "$namespace" apply --dry-run=server \
  -f "$work/manifest.yaml" >/dev/null
export TOPIC_PREFIX
TOPIC_PREFIX="$(python3 - "$work/manifest.yaml" "$config" "$namespace" "$work" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
import yaml
graphs = [r for r in yaml.safe_load_all(open(sys.argv[1])) if r and r["kind"] == "DataflowGraph"]
assert len(graphs) == 3, "Expected the three installed sample graphs"
def get(kind, name):
    return json.loads(subprocess.check_output([
        "kubectl", "--kubeconfig", sys.argv[2], "--namespace", sys.argv[3],
        "get", kind, name, "-o", "json",
    ], text=True))
prefixes = set()
profiles = {}
live_graphs = []
for graph in graphs:
    live = get("dataflowgraph", graph["metadata"]["name"])
    live_graphs.append(live)
    spec = live["spec"]
    assert "instanceCount" not in spec, "instanceCount belongs to DataflowProfile, not DataflowGraph"
    for key in ("profileRef", "mode", "nodes", "nodeConnections"):
        assert spec[key] == graph["spec"][key], f"Live graph differs from Helm manifest: {key}"
    profile_name = spec["profileRef"]
    if profile_name not in profiles:
        profiles[profile_name] = get("dataflowprofile", profile_name)
    assert profiles[profile_name]["spec"]["instanceCount"] == 1, (
        f"DataflowProfile {profile_name} must have spec.instanceCount=1; it will not be modified")
    for node in spec["nodes"]:
        if node["nodeType"] == "Source":
            prefixes.update(topic.rsplit("/", 1)[0] for topic in node["sourceSettings"]["dataSources"])
assert len(prefixes) == 1, "All sample graphs must share one isolated prefix"
Path(sys.argv[4], "live-resources.json").write_text(json.dumps({
    "graphs": live_graphs, "profiles": list(profiles.values()),
}, indent=2) + "\n")
print(prefixes.pop())
PY
)"
python3 "$scripts/../chart/files/verify_runtime.py"
