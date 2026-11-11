#!/usr/bin/env bash
# No implicit current context, runtime installation, or production workflow integration.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: MQTT_HOST=host [MQTT_PORT=1883 MQTT_TLS=true] bash scripts/verify-deployed.sh KUBECONFIG NAMESPACE FRESH_RELEASE" >&2
  echo "Requires kubectl, Helm, Python, PyYAML and paho-mqtt==2.1.0. Install a fresh release into an existing qualified AIO runtime first." >&2
  echo "Waits for AIO 1.6 worker/graph health before publishing; RUNTIME_READY_TIMEOUT defaults to 600 seconds. Requires read access to profile pods and health ConfigMaps." >&2
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
  -f "$work/manifest.yaml" -o yaml > "$work/validated-manifest.yaml"
export TOPIC_PREFIX
TOPIC_PREFIX="$(python3 - "$work/validated-manifest.yaml" "$config" "$namespace" "$work" <<'PY'
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
import yaml
def timestamp(value):
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", value).replace("Z", "+00:00"))

def get(kind, name, optional=False):
    command = [
        "kubectl", "--kubeconfig", sys.argv[2], "--namespace", sys.argv[3],
        "get", kind, name, "-o", "json",
    ]
    if optional:
        command.append("--ignore-not-found")
    result = subprocess.check_output(command, text=True)
    return json.loads(result) if result.strip() else {}

def runtime_ready(graphs, profiles):
    for name, profile in profiles.items():
        pod = get("pod", f"aio-dataflow-{name}-0", optional=True)
        if (pod.get("metadata", {}).get("deletionTimestamp")
                or not any(c["type"] == "Ready" and c["status"] == "True"
                           for c in pod.get("status", {}).get("conditions", []))):
            return False
        health = get("configmap", f"aio-dataflow-{name}-health-status-configmap",
                     optional=True)
        if not any(owner.get("uid") == profile["metadata"]["uid"]
                   for owner in health.get("metadata", {}).get("ownerReferences", [])):
            return False
        started = timestamp(pod["metadata"]["creationTimestamp"])
        for graph in graphs:
            if graph["spec"]["profileRef"] != name:
                continue
            for component in ("source", "transform", "destination"):
                key = f'0.dfg.{graph["metadata"]["name"]}.{component}'
                status = json.loads(health.get("data", {}).get(key, "{}"))
                if (status.get("s") != "Available" or not status.get("lu")
                        or timestamp(status["lu"]) < started):
                    return False
    return True

def wait_for_runtime(graphs, profiles):
    timeout = float(os.environ.get("RUNTIME_READY_TIMEOUT", "600"))
    if not 0 < timeout < float("inf"):
        raise ValueError("RUNTIME_READY_TIMEOUT must be a positive finite number of seconds")
    deadline = time.monotonic() + timeout
    while not runtime_ready(graphs, profiles):
        if time.monotonic() >= deadline:
            raise TimeoutError("Runtime not ready: require worker Ready and current AIO 1.6 "
                               "source/transform/destination health Available for every graph")
        time.sleep(min(5, max(0, deadline - time.monotonic())))

resources = []
with open(sys.argv[1]) as manifest:
    for resource in yaml.safe_load_all(manifest):
        if resource:
            resources.extend(resource["items"] if resource["kind"] == "List" else [resource])
graphs = [r for r in resources if r["kind"] == "DataflowGraph"]
assert len(graphs) == 8, "Expected the eight installed sample graphs"
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
wait_for_runtime(live_graphs, profiles)
print(prefixes.pop())
PY
)"
python3 "$scripts/../chart/files/verify_runtime.py"
