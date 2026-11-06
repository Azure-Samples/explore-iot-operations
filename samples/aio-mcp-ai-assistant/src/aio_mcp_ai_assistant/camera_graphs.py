import json
from pathlib import Path

import yaml

from .common import JsonObject, SampleError
from .config import Settings

REPOSITORY = "azure-samples/aio-mcp-ai-assistant/camera-actions"
STAGES = {"get-status": "GetStatus", "continuous-move": "ContinuousMove", "stop": "Stop"}


def graph(stage: str, version: str) -> JsonObject:
    return {
        "metadata": {
            "name": f"Camera {STAGES[stage]}",
            "description": "Bounded ONVIF managed-action invocation for a data flow graph.",
            "version": version,
            "$schema": "https://www.schemastore.org/aio-wasm-graph-config-1.1.0.json",
            "vendor": "Microsoft samples",
        },
        "moduleRequirements": {"apiVersion": "1.7.2", "runtimeVersion": "1.1.8"},
        "moduleConfigurations": [
            {
                "name": "invoke",
                "parameters": {
                    name: {
                        "name": name,
                        "description": description,
                        "required": True,
                        "schema": json.dumps({"type": "string"}),
                    }
                    for name, description in (
                        ("asset_name", "Registered ONVIF control Asset."),
                        ("profile_token", "Authorized ONVIF media profile."),
                    )
                },
            }
        ],
        "operations": [
            {"operationType": "source", "name": "input"},
            {"operationType": "map", "name": "invoke", "module": f"{REPOSITORY}/{stage}:{version}"},
            {"operationType": "sink", "name": "output"},
        ],
        "connections": [
            {"from": {"name": "input"}, "to": {"name": "invoke"}},
            {"from": {"name": "invoke"}, "to": {"name": "output"}},
        ],
    }


def write_camera_graphs(settings: Settings, destination: Path) -> None:
    artifacts = settings.camera_graphs
    if artifacts is None:
        raise SampleError("cameraGraphs must be configured")
    for stage in STAGES:
        (destination / f"camera-{stage}-graph.yaml").write_text(
            yaml.safe_dump(graph(stage, artifacts.artifact_version), sort_keys=False),
            encoding="utf-8",
        )
    parameters = {
        "dataflowProfileName": settings.camera_profile_name,
        "registryEndpointName": artifacts.registry_endpoint_name,
        "artifactVersion": artifacts.artifact_version,
        "cameraAssetName": settings.camera.asset_name,
        "profileToken": settings.camera.profile_token,
        "topicPrefix": settings.camera.topic_prefix,
    }
    (destination / "camera-actions.parameters.json").write_text(
        json.dumps(
            {
                "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
                "contentVersion": "1.0.0.0",
                "parameters": {key: {"value": value} for key, value in parameters.items()},
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
