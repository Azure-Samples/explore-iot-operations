#!/usr/bin/env python3
"""Stamp a disposable copy, never the checked-in crate or graphs."""
import argparse
import json
import re
import shutil
from pathlib import Path

import yaml

BASE = Path(__file__).resolve().parents[1]
GRAPHS = ("graph-align-by-time", "graph-correlate-by-id", "graph-versioned-predictor")
REPOSITORY = "azure-samples/explore-iot-operations/dataflow-patterns"
NUMBER = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)"
SEMVER = re.compile(rf"{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{IDENTIFIER}(?:\.{IDENTIFIER})*)?")


def validate_version(version):
    if len(version) > 128 or not SEMVER.fullmatch(version):
        raise ValueError("Expected SemVer without build metadata, at most 128 characters")
    return version


def validate_graph(graph, version=None):
    operations = [op for op in graph["operations"] if op.get("module")
                  or op.get("operationType") in ("map", "filter")]
    if (len(operations) != 2
            or sorted(op.get("operationType", "") for op in operations) != ["filter", "map"]):
        raise ValueError("Graph must have exactly one map and one filter module reference")
    expected = f"{REPOSITORY}/module-dataflow-patterns:"
    modules = []
    for operation in operations:
        module = operation.get("module", "")
        if not isinstance(module, str) or not module.startswith(expected):
            raise ValueError(f"Unexpected module reference: {module}")
        validate_version(module[len(expected):])
        modules.append(module)
    if len(set(modules)) != 1:
        raise ValueError("Map and filter must reference the same module version")
    if version is not None and (modules[0] != expected + version
                                or graph["metadata"]["version"] != version):
        raise ValueError("Graph and both module references must use the release version")
    return operations


def stamp_graph(graph, version):
    validate_version(version)
    operations = validate_graph(graph)
    graph["metadata"]["version"] = version
    for operation in operations:
        operation["module"] = f"{REPOSITORY}/module-dataflow-patterns:{version}"
    return graph


def prepare(version, revision, output):
    validate_version(version)
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be the full source commit SHA")
    if output.exists():
        raise ValueError(f"Output already exists: {output}; use a fresh directory")
    source = output / "source"
    shutil.copytree(BASE, source, ignore=shutil.ignore_patterns("chart", "scripts", "target", ".git"))
    for filename in ("Cargo.toml", "Cargo.lock"):
        path = source / filename
        text = path.read_text()
        pattern = r'(\[package\]\s*\nname = "module-dataflow-patterns"\s*\nversion = ")[^"]+(")'
        if filename == "Cargo.lock":
            pattern = r'(\[\[package\]\]\s*\nname = "module-dataflow-patterns"\s*\nversion = ")[^"]+(")'
        text, count = re.subn(pattern, lambda m: m[1] + version + m[2], text)
        if count != 1:
            raise ValueError(f"Cannot stamp package version in {filename}")
        path.write_text(text)
    artifacts = output / "artifacts"
    artifacts.mkdir()
    for name in GRAPHS:
        candidates = list(source.glob(f"**/{name}.yaml"))
        if len(candidates) != 1:
            raise ValueError(f"Expected one {name}.yaml; found {len(candidates)}")
        graph = stamp_graph(yaml.safe_load(candidates[0].read_text()), version)
        (artifacts / f"{name}.yaml").write_text(yaml.safe_dump(graph, sort_keys=False))
    shutil.copytree(BASE / "chart", output / "chart")
    chart_path = output / "chart" / "Chart.yaml"
    chart = yaml.safe_load(chart_path.read_text())
    chart.update(version=version, appVersion=version)
    chart.setdefault("annotations", {})["org.opencontainers.image.revision"] = revision
    chart["annotations"]["org.opencontainers.image.url"] = (
        f"https://github.com/Azure-Samples/explore-iot-operations/tree/{revision}"
    )
    chart_path.write_text(yaml.safe_dump(chart, sort_keys=False))
    values_path = output / "chart" / "values.yaml"
    values = yaml.safe_load(values_path.read_text())
    values["artifactVersion"] = version
    values_path.write_text(yaml.safe_dump(values, sort_keys=False))
    (output / "release.json").write_text(json.dumps({
        "version": version,
        "revision": revision,
        "dependencies": [],
        "runtimeVerified": False,
        "chartDefaults": {
            "endpointRef": values["endpointRef"],
            "profile": values["profile"],
            "profileRef": values["profileRef"],
            "profileInstanceCount": 1,
            "registryHost": "ghcr.io",
            "registryPullSecret": values["registryPullSecret"],
            "artifactRepository": values["artifactRepository"],
            "artifactVersion": version,
            "topicPrefix": "dataflow-patterns/<release>",
            "tests": values["tests"],
        },
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.version, args.revision, args.output.resolve())
