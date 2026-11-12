#!/usr/bin/env python3
"""Render customer-specific manifests without contacting Azure or Kubernetes."""

import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parent
REPOSITORY = "azure-samples/edge-predictive-inference"


def load_config(path: Path) -> dict:
    config = json.loads(path.read_text())
    schema = json.loads((ROOT / "config.schema.json").read_text())
    jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(
        config
    )
    serialized = json.dumps(config, allow_nan=False)
    if "REPLACE_WITH_" in serialized:
        raise ValueError("Replace every REPLACE_WITH_ value in the configuration")
    for key in ("cameraUrl", "modelEndpoint"):
        url = urlsplit(config[key])
        if not url.hostname or url.username is not None or url.password is not None or url.fragment:
            raise ValueError(f"{key} must have a host, no embedded credentials, and no fragment")
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError(f"{key} must have a valid port")
    endpoint = urlsplit(config["modelEndpoint"])
    if endpoint.query or endpoint.path.rstrip("/").endswith(("/v1/predict", "/v1/model")):
        raise ValueError(
            "modelEndpoint must be the deployment base URL, without API suffix or query"
        )
    config["modelEndpoint"] = config["modelEndpoint"].rstrip("/")
    return config


def substitute(value, config: dict):
    if isinstance(value, dict):
        return {key: substitute(item, config) for key, item in value.items()}
    if isinstance(value, list):
        return [substitute(item, config) for item in value]
    if isinstance(value, str):
        match = re.fullmatch(r"\$\{([A-Za-z]+)\}", value)
        if match:
            return config[match[1]]
        if "${" in value:
            raise ValueError(f"Unresolved template expression: {value}")
    return value


def graph(stage: str, version: str) -> dict:
    descriptions = {
        "preprocess": "Decode JPEG, letterbox BGR CHW tensor, and write the input file.",
        "postprocess": "Read the raw model output, decode person boxes, and publish an observation.",
    }
    parameters = {}
    for key, description, kind in [
        ("camera_id", "Logical camera/asset identifier.", "string"),
        ("model_name", "Name of the model served by the inference connector.", "string"),
        ("score_threshold", "Minimum objectness times person probability.", "number"),
        ("nms_threshold", "Maximum box IoU before suppression.", "number"),
    ]:
        parameters[key] = {
            "name": key,
            "description": description,
            "required": True,
            "schema": json.dumps({"type": kind}),
        }
    return {
        "metadata": {
            "name": f"YOLOX person {stage}",
            "description": descriptions[stage],
            "version": version,
            "$schema": "https://www.schemastore.org/aio-wasm-graph-config-1.1.0.json",
            "vendor": "Microsoft samples",
        },
        "moduleConfigurations": [{"name": stage, "parameters": parameters}],
        "moduleRequirements": {"apiVersion": "1.7.2", "runtimeVersion": "1.1.8"},
        "operations": [
            {"operationType": "source", "name": "input", "arity": 1},
            {
                "operationType": "map",
                "name": stage,
                "module": f"{REPOSITORY}/{stage}:{version}",
            },
            {"operationType": "sink", "name": "output", "arity": 1},
        ],
        "connections": [
            {"from": {"name": "input"}, "to": {"name": stage}},
            {"from": {"name": stage}, "to": {"name": "output"}},
        ],
    }


def render(config: dict, output: Path) -> None:
    if output.resolve() in [
        ROOT,
        ROOT / "bicep",
        ROOT / "kubernetes",
        ROOT / "models",
        ROOT / "wasm",
    ]:
        raise ValueError("Render into a separate generated directory, not the sample source")
    common = {key: config[key] for key in ("aioInstanceName", "customLocationName")}
    parameter_sets = {
        "definition": common,
        "connector": {
            **common,
            **{
                key: config[key]
                for key in ("dataClaimName", "modelName", "modelEndpoint", "foundryTrustSecret")
            },
        },
        "camera": {
            **{
                key: config[key]
                for key in (
                    "customLocationName",
                    "adrNamespaceName",
                    "adrNamespaceLocation",
                    "cameraId",
                    "cameraUrl",
                    "cameraAuthentication",
                    "topicPrefix",
                )
            },
            "enabled": False,
        },
        "dataflow": {
            **common,
            **{
                key: config[key]
                for key in (
                    "dataClaimName",
                    "registryEndpointName",
                    "artifactVersion",
                    "cameraId",
                    "modelName",
                    "topicPrefix",
                )
            },
            "scoreThreshold": str(config["scoreThreshold"]),
            "nmsThreshold": str(config["nmsThreshold"]),
            "mode": "Disabled",
        },
    }
    files = {}
    for name, parameters in parameter_sets.items():
        files[f"{name}.parameters.json"] = (
            json.dumps(
                {
                    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
                    "contentVersion": "1.0.0.0",
                    "parameters": {key: {"value": value} for key, value in parameters.items()},
                },
                indent=2,
                allow_nan=False,
            )
            + "\n"
        )
    for template in sorted((ROOT / "kubernetes").glob("*.yaml")):
        documents = [
            substitute(document, config) for document in yaml.safe_load_all(template.read_text())
        ]
        files[template.name] = yaml.safe_dump_all(documents, sort_keys=False)
    for stage in ("preprocess", "postprocess"):
        files[f"{stage}-graph.yaml"] = yaml.safe_dump(
            graph(stage, config["artifactVersion"]), sort_keys=False
        )
    output.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (output / name).write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / ".generated")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        render(config, args.output)
    except (OSError, ValueError, jsonschema.ValidationError) as error:
        parser.exit(1, f"Configuration/rendering failed: {error}\n")
    print(f"Rendered disabled camera/dataflow and deployment artifacts in {args.output}")


if __name__ == "__main__":
    main()
