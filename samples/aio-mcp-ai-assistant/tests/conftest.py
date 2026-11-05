import json
from pathlib import Path

import pytest

from aio_mcp_ai_assistant.config import Settings
from aio_mcp_ai_assistant.frontend import BUILTIN_SCHEMAS

ROOT = Path(__file__).resolve().parents[1]


def builtin_tools():
    return [
        {
            "name": name,
            "inputSchema": {
                "type": "object",
                "properties": {field: {"type": kind} for field, kind in fields.items()},
            },
        }
        for name, fields in BUILTIN_SCHEMAS.items()
    ]


@pytest.fixture
def config():
    value = json.loads((ROOT / "config.example.json").read_text())
    value["kubeContext"] = "test-context"
    value["image"] = "example.azurecr.io/samples/edge-assistant:0.1.0"
    value["imagePullSecret"] = ""
    value["foundry"]["tokenAudience"] = "foundry-local"
    return value


@pytest.fixture
def settings(config):
    return Settings.model_validate(config)


@pytest.fixture
def template_dir():
    return ROOT / "kubernetes"


@pytest.fixture
def action_settings(config):
    config["camera"]["enabled"] = True
    config["recommendations"]["enabled"] = True
    config["cameraGraphs"] = {
        "registry": "example.azurecr.io",
        "registryEndpointName": "camera-registry",
        "artifactVersion": "0.1.0",
    }
    return Settings.model_validate(config)


@pytest.fixture
def recommendation():
    return {
        "idempotency_key": "test-recommendation-1",
        "recommendation": {
            "summary": "Check the simulated camera.",
            "severity": "LOW",
            "actions": ["Have an operator inspect the camera configuration."],
            "evidence": ["Synthetic fixture; no real operational incident."],
        },
    }
