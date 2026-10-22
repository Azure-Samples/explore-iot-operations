#!/usr/bin/env python3
"""Stamp a disposable copy, never the checked-in crate or graphs."""
import argparse
import json
import re
import shutil
from pathlib import Path

import yaml

BASE = Path(__file__).resolve().parents[1]
GRAPHS = (
    "graph-align-by-time", "graph-correlate-by-id", "graph-versioned-predictor",
    "graph-report-by-exception", "graph-stable-alarm", "graph-offline-detection",
    "graph-running-total", "graph-smooth-readings",
)
REPOSITORY = "azure-samples/explore-iot-operations/dataflow-patterns"
TICKER_REPOSITORY = "ghcr.io/azure-samples/explore-iot-operations/dataflow-pattern-ticker"
MODULES = {"map": "module-dataflow-patterns", "filter": "module-dataflow-pattern-filter"}
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
    versions = []
    for operation in operations:
        expected = f"{REPOSITORY}/{MODULES[operation['operationType']]}:"
        module = operation.get("module", "")
        if not isinstance(module, str) or not module.startswith(expected):
            raise ValueError(f"Unexpected module reference: {module}")
        versions.append(validate_version(module[len(expected):]))
    if len(set(versions)) != 1:
        raise ValueError("Map and filter must reference the same module version")
    if version is not None and (versions[0] != version
                                or graph["metadata"]["version"] != version):
        raise ValueError("Graph and both module references must use the release version")
    return operations


def stamp_graph(graph, version):
    validate_version(version)
    operations = validate_graph(graph)
    graph["metadata"]["version"] = version
    for operation in operations:
        operation["module"] = f"{REPOSITORY}/{MODULES[operation['operationType']]}:{version}"
    return graph


def stamp_package(path, name, version, *, lock=False):
    text = path.read_text()
    header = r"\[\[package\]\]" if lock else r"\[package\]"
    count = 0

    def replace(match):
        nonlocal count
        block = match[0]
        if not re.search(rf'(?m)^name[ \t]*=[ \t]*"{re.escape(name)}"[ \t]*(?:#.*)?$', block):
            return block
        stamped, versions = re.subn(
            r'(?m)^(version\s*=\s*")[^"]+(".*)$',
            lambda m: m[1] + version + m[2], block,
        )
        if versions != 1:
            raise ValueError(f"Cannot stamp package version for {name} in {path}")
        count += 1
        return stamped

    text = re.sub(rf"(?ms)^{header}[ \t]*\n.*?(?=^\[|\Z)", replace, text)
    if count != 1:
        raise ValueError(f"Expected one package {name} in {path}; found {count}")
    path.write_text(text)


def stamp_manifests(directory, version):
    validate_version(version)
    paths = sorted(set(directory.rglob("*.yaml")) | set(directory.rglob("*.yml")))
    documents = {path: list(yaml.safe_load_all(path.read_text())) for path in paths}
    registries = {
        (doc.get("metadata", {}).get("namespace"), doc["metadata"]["name"]): doc["spec"]["host"]
        for docs in documents.values() for doc in docs
        if isinstance(doc, dict) and doc.get("kind") == "RegistryEndpoint"
    }
    for path, docs in documents.items():
        changed = False
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "DataflowGraph":
                continue
            for node in doc["spec"]["nodes"]:
                settings = node.get("graphSettings")
                if settings is None:
                    continue
                registry = (doc.get("metadata", {}).get("namespace"),
                            settings["registryEndpointRef"])
                if registries.get(registry) != "ghcr.io":
                    raise ValueError(f"Expected a ghcr.io graph registry in {path}")
                artifact = settings.get("artifact", "")
                prefix = "ghcr.io/" if isinstance(artifact, str) and artifact.startswith("ghcr.io/") else ""
                match = re.fullmatch(
                    rf"{re.escape(prefix + REPOSITORY)}/({'|'.join(map(re.escape, GRAPHS))}):(.+)",
                    artifact if isinstance(artifact, str) else "",
                )
                if not match:
                    raise ValueError(f"Unexpected graph reference: {artifact}")
                validate_version(match[2])
                settings["artifact"] = f"{prefix}{REPOSITORY}/{match[1]}:{version}"
                changed = True
        if changed:
            path.write_text(yaml.safe_dump_all(docs, sort_keys=False))


def prepare(version, revision, output):
    validate_version(version)
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be the full source commit SHA")
    if output.exists():
        raise ValueError(f"Output already exists: {output}; use a fresh directory")
    source = output / "source"
    shutil.copytree(BASE, source, ignore=shutil.ignore_patterns("chart", "scripts", "target", ".git"))
    for role, name in MODULES.items():
        manifest = source / ("filter/Cargo.toml" if role == "filter" else "Cargo.toml")
        stamp_package(manifest, name, version)
        stamp_package(source / "Cargo.lock", name, version, lock=True)
    artifacts = output / "artifacts"
    artifacts.mkdir()
    for name in GRAPHS:
        candidates = list(source.glob(f"**/{name}.yaml"))
        if len(candidates) != 1:
            raise ValueError(f"Expected one {name}.yaml; found {len(candidates)}")
        graph = stamp_graph(yaml.safe_load(candidates[0].read_text()), version)
        stamped = yaml.safe_dump(graph, sort_keys=False)
        candidates[0].write_text(stamped)
        (artifacts / f"{name}.yaml").write_text(stamped)
    stamp_manifests(source / "manifests", version)
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
    ticker = values.setdefault("ticker", {})
    ticker.setdefault("enabled", False)
    ticker.setdefault("image", {}).update(repository=TICKER_REPOSITORY, tag=version)
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
            "ticker": ticker,
        },
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.version, args.revision, args.output.resolve())
