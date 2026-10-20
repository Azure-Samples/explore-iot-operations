#!/usr/bin/env python3
"""Check rendered chart wiring; Helm validates values against values.schema.json."""
import argparse
import json
import subprocess

import yaml

from pathlib import Path


def check(chart, version, revision=None):
    subprocess.run(["helm", "lint", str(chart), "--strict"], check=True)
    for release, prefix in (("sample", "dataflow-patterns/sample"), ("other", "isolated/test")):
        command = ["helm", "template", release, str(chart), "--namespace", "azure-iot-operations"]
        if release == "other":
            command += ["--set", f"topicPrefix={prefix}", "--set", "endpointRef=customer-mqtt"]
        resources = list(yaml.safe_load_all(subprocess.check_output(command, text=True)))
        assert len(resources) == 5, "Expected a RegistryEndpoint, a dedicated profile and three graphs"
        profile = next(r for r in resources if r["kind"] == "DataflowProfile")
        assert profile["spec"] == {"instanceCount": 1}, "Use the operator's native image defaults"
        assert len(profile["metadata"]["name"]) <= 39
        registry = next(r for r in resources if r["kind"] == "RegistryEndpoint")
        assert registry["spec"] == {"host": "ghcr.io", "authentication": {
            "method": "Anonymous", "anonymousSettings": {}}}
        outputs, inputs = set(), set()
        expected = {
            "graph-align-by-time": ({"speed", "temperature"}, "aligned"),
            "graph-correlate-by-id": ({"predictions", "measurements"}, "matches"),
            "graph-versioned-predictor": ({"readings", "models"}, "predictions-from-updates"),
        }
        for graph in (r for r in resources if r["kind"] == "DataflowGraph"):
            assert graph["apiVersion"] == "connectivity.iotoperations.azure.com/v1"
            assert graph["metadata"]["namespace"] == "azure-iot-operations"
            assert len(graph["metadata"]["name"]) <= 63
            spec = graph["spec"]
            assert "instanceCount" not in spec and spec["mode"] == "Enabled"
            assert spec["profileRef"] == profile["metadata"]["name"]
            nodes = {n["name"]: n for n in spec["nodes"]}
            settings = nodes["transform"]["graphSettings"]
            assert settings["registryEndpointRef"] == registry["metadata"]["name"]
            artifact = settings["artifact"]
            name, tag = artifact.rsplit("/", 1)[1].split(":")
            assert tag == version
            assert artifact == f"azure-samples/explore-iot-operations/dataflow-patterns/{name}:{version}"
            topics, destination = expected.pop(name)
            actual_inputs = set(nodes["source"]["sourceSettings"]["dataSources"])
            actual_output = nodes["destination"]["destinationSettings"]["dataDestination"]
            assert actual_inputs == {f"{prefix}/{topic}" for topic in topics}
            assert actual_output == f"{prefix}/{destination}"
            endpoint = "default" if release == "sample" else "customer-mqtt"
            assert nodes["source"]["sourceSettings"]["endpointRef"] == endpoint
            assert nodes["destination"]["destinationSettings"]["endpointRef"] == endpoint
            assert spec["nodeConnections"] == [
                {"from": {"name": "source"}, "to": {"name": "transform"}},
                {"from": {"name": "transform"}, "to": {"name": "destination"}},
            ]
            outputs.add(actual_output)
            inputs.update(actual_inputs)
        assert not expected and not outputs.intersection(inputs), "Topic feedback detected"
    metadata = yaml.safe_load(subprocess.check_output(["helm", "show", "chart", str(chart)], text=True))
    assert metadata["version"] == metadata["appVersion"] == version
    if revision:
        assert metadata["annotations"]["org.opencontainers.image.revision"] == revision
    # Reject unknown values, unsafe topics and scaling of local state.
    for value in ("instanceCount=2", "profile.instanceCount=2", "profile.create=false",
                  "profileRef=default", "topicPrefix=unsafe/+", "endpointRef=", "unknown=true"):
        result = subprocess.run(["helm", "template", "invalid", str(chart), "--set", value],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert result.returncode != 0, f"Schema accepted {value}"
    result = subprocess.run([
        "helm", "template", "offline", str(chart), "--set", "profile.create=false",
        "--set", "profileRef=default",
    ], capture_output=True, text=True)
    assert result.returncode != 0 and "must be readable" in result.stderr, (
        "Offline rendering must not bypass existing profile verification")
    rendered_tests = subprocess.check_output([
        "helm", "template", "sample", str(chart), "--set", "tests.enabled=true",
        "--set", "tests.mqttHost=real-broker"], text=True)
    tests = list(yaml.safe_load_all(rendered_tests))
    config = next(r for r in tests if r["kind"] == "ConfigMap")
    assert "verify_runtime.py" in config["data"], "Published chart must contain its runtime tests"
    assert any(r["kind"] == "Pod" and r["metadata"]["annotations"].get("helm.sh/hook") == "test"
               for r in tests)
    authenticated = list(yaml.safe_load_all(subprocess.check_output([
        "helm", "template", "sample", str(chart), "--set", "registryPullSecret=existing-ghcr-secret",
    ], text=True)))
    registry = next(r for r in authenticated if r["kind"] == "RegistryEndpoint")
    assert registry["spec"] == {"host": "ghcr.io", "authentication": {
        "method": "ArtifactPullSecret", "artifactPullSecretSettings": {"secretRef": "existing-ghcr-secret"}}}
    assert not any(r["kind"] == "Secret" for r in authenticated)
    print(json.dumps({"chart": str(chart), "version": version, "wiring": "passed"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chart", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision")
    args = parser.parse_args()
    check(args.chart, args.version, args.revision)
