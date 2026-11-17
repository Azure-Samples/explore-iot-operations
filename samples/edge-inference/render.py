"""Render local configuration into reviewable Kubernetes and ARM parameter files."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
from string import Template
from urllib.parse import urlsplit

from jsonschema import Draft202012Validator

from inspection import JsonObject, encode, validate_scenarios

ROOT = Path(__file__).resolve().parent


def validate_config(config: JsonObject) -> None:
    schema = json.loads((ROOT / "config.schema.json").read_text())
    problems = []
    for error in Draft202012Validator(schema).iter_errors(config):
        path = ".".join(str(part) for part in error.absolute_path) or "configuration"
        if error.validator == "required":
            missing = sorted(set(error.validator_value) - error.instance.keys())
            problems.append(f"{path}: missing required fields: {', '.join(missing)}")
        elif error.validator in ("additionalProperties", "oneOf", "pattern", "not"):
            problems.append(f"{path}: invalid {error.validator} constraint; see config.schema.json")
        else:
            problems.append(f"{path}: expected {error.validator}={encode(error.validator_value)}")
    if problems:
        raise ValueError("Invalid configuration:\n" + "\n".join(sorted(problems)))
    if "REPLACE_WITH" in json.dumps(config):
        raise ValueError("Replace every REPLACE_WITH value in config.json before rendering")
    if config["dataClaimName"] == config["stateClaimName"]:
        raise ValueError(
            "dataClaimName and stateClaimName must reference different, dedicated PVCs"
        )
    for name in config["enabledScenarios"]:
        if name not in config["cameras"]:
            raise ValueError(f"cameras.{name}: configure the selected scenario's camera")
    for name, camera in config["cameras"].items():
        try:
            url = urlsplit(camera["address"])
            port = url.port
        except ValueError as failure:
            raise ValueError(f"cameras.{name}.address: invalid URL hostname or port") from failure
        if url.scheme not in ("rtsp", "rtsps") or not url.hostname:
            raise ValueError(f"cameras.{name}.address: an RTSP or RTSPS hostname is required")
        if url.username is not None or url.password is not None:
            raise ValueError(
                f"cameras.{name}: use Device secret references, not credentials in the URL"
            )
        if port is not None and not 1 <= port <= 65535:
            raise ValueError(f"cameras.{name}.address: the port must be in [1,65535]")
    if config["graphs"]["inference"].endswith(":0.2.0-preview.0"):
        raise ValueError(
            "Inference graph 0.2 has an incompatible response envelope; use the 0.3 contract"
        )


def prepared_scenarios(config: JsonObject, models: Path) -> list[JsonObject]:
    catalog = json.loads((ROOT / "models/catalog.json").read_text())
    scenarios = [
        item
        for item in json.loads((ROOT / "scenarios.json").read_text())
        if item["name"] in config["enabledScenarios"]
    ]
    for scenario in scenarios:
        name = scenario["name"]
        model = catalog[name]
        package = models / name / "package"
        try:
            provenance = json.loads((package / "provenance.json").read_text())
            labels = json.loads((package / "config.json").read_text())
            if (
                not isinstance(provenance, dict)
                or not isinstance(labels, dict)
                or "id2label" not in labels
                or any(
                    provenance.get(key) != model[key]
                    for key in ("repository", "revision", "sha256")
                )
                or provenance.get("outputTensorKey") != "detections_0"
            ):
                raise ValueError(f"Prepared {name} metadata does not match models/catalog.json")
            for filename, key in (
                ("model.onnx", "packagedModelSha256"),
                ("config.json", "packagedConfigSha256"),
            ):
                digest = hashlib.sha256()
                with (package / filename).open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != provenance.get(key):
                    raise ValueError(
                        f"Prepared {name}/{filename} changed; prepare and publish the model again"
                    )
        except FileNotFoundError as failure:
            raise ValueError(
                f"Prepared model files for {name} are missing; run models/prepare.py prepare --scenario {name}"
            ) from failure
        scenario["classLabels"] = labels["id2label"]
        scenario["modelProvenance"] = {
            "repository": model["repository"],
            "revision": model["revision"],
            "sourceSha256": model["sha256"],
            "deploymentTag": config["modelTag"],
            "packagedModelSha256": provenance["packagedModelSha256"],
            "packagedConfigSha256": provenance["packagedConfigSha256"],
            "adapter": "Foundry ImageNet normalization inversion; detections_0 output",
        }
    validate_scenarios(scenarios)
    return scenarios


def json_document(value: object) -> str:
    return json.dumps(value, indent=2, allow_nan=False) + "\n"


def render(
    config: JsonObject,
    output: Path,
    replay: bool = False,
    models: Path = ROOT / ".assets/models",
) -> None:
    validate_config(config)
    scenarios = prepared_scenarios(config, models)
    documents = {"scenarios.json": json_document(scenarios)}

    def yaml_file(name: str, target: str | None = None, **values: object) -> None:
        text = Template((ROOT / "kubernetes" / f"{name}.yaml").read_text()).substitute(
            {key: json.dumps(value) for key, value in values.items()}
        )
        documents[f"{target or name}.yaml"] = text

    common = {
        "DATA_CLAIM": config["dataClaimName"],
        "STATE_CLAIM": config["stateClaimName"],
        "COLLECTOR_IMAGE": config["collectorImage"],
        "IMAGE_PULL_SECRET": config["imagePullSecret"],
        "SCENARIOS_HASH": hashlib.sha256(encode(scenarios).encode()).hexdigest(),
    }
    for name in ("collector", "storage-init", "response-cleanup"):
        yaml_file(name, **common)
    yaml_file(
        "media-template",
        MEDIA_TEMPLATE_NAME=config["mediaTemplateName"],
        MEDIA_REGISTRY=config["mediaImage"]["registry"],
        MEDIA_IMAGE=config["mediaImage"]["name"],
        MEDIA_TAG=config["mediaImage"]["tag"],
        **common,
    )
    for scenario in scenarios:
        name = scenario["name"]
        yaml_file(
            "camera",
            f"camera-{name}",
            DEVICE_NAME=scenario["deviceName"],
            ASSET_NAME=scenario["assetName"],
            CAMERA_URL=config["cameras"][name]["address"],
            CAMERA_AUTHENTICATION=config["cameras"][name]["authentication"],
            ACTION_TOPIC=f"azure-iot-operations/asset-operations/{scenario['assetName']}/control/ExtractClip",
        )
        yaml_file(
            "model",
            f"model-{name}",
            MODEL_NAME=scenario["modelName"],
            FOUNDRY_NAMESPACE=config["foundryNamespace"],
            MODEL_REGISTRY=config["modelRegistry"],
            MODEL_REPOSITORY=f"models/edge-inference/{name}",
            MODEL_TAG=config["modelTag"],
            MODEL_REGISTRY_SECRET=config["modelRegistrySecret"],
        )
        if replay:
            image = ROOT / ".assets/replay" / f"{name}.jpg"
            data = image.read_bytes()
            if len(data) > 500 * 1024:
                raise ValueError(f"Replay image exceeds the ConfigMap limit: {image}")
            yaml_file(
                "replay",
                f"replay-{name}",
                REPLAY_NAME=f"edge-replay-{name}",
                IMAGE_BASE64=base64.b64encode(data).decode("ascii"),
                REPLAY_HASH=hashlib.sha256(
                    (ROOT / "kubernetes/replay.yaml").read_bytes() + data
                ).hexdigest(),
            )
    config_map = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "edge-inference-scenarios",
            "namespace": "azure-iot-operations",
            "labels": {"app.kubernetes.io/part-of": "edge-inference-sample"},
        },
        "data": {"scenarios.json": json.dumps(scenarios)},
    }
    documents["scenarios-configmap.json"] = json_document(config_map)
    common_parameters = {
        "aioInstanceName": config["aioInstanceName"],
        "customLocationName": config["customLocationName"],
    }
    parameters = {
        "definition": {**common_parameters, "image": config["inferenceImage"]},
        "connector": {
            **common_parameters,
            "scenarios": scenarios,
            "dataClaimName": config["dataClaimName"],
            "foundryNamespace": config["foundryNamespace"],
            "trustBundleName": config["foundryTrustSecret"],
        },
        "dataflows": {
            **common_parameters,
            "scenarios": scenarios,
            "dataClaimName": config["dataClaimName"],
            "registryEndpointName": config["graphRegistryEndpointName"],
            "graphs": config["graphs"],
        },
    }
    for name, values in parameters.items():
        document = {
            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
            "contentVersion": "1.0.0.0",
            "parameters": {key: {"value": value} for key, value in values.items()},
        }
        documents[f"{name}.parameters.json"] = json_document(document)
    output.mkdir(parents=True, exist_ok=True)
    for name, contents in documents.items():
        (output / name).write_text(contents)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / ".generated")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--replay", action="store_true")
    parser.add_argument("--models", type=Path, default=ROOT / ".assets/models")
    mode.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate configuration without loading models or writing files",
    )
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        if args.validate_only:
            validate_config(config)
            return 0
        render(config, args.output, args.replay, args.models)
    except (OSError, ValueError) as failure:
        parser.exit(1, f"Configuration error: {failure}\n")
    print(f"Rendered resources to {args.output}; review them before applying")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
