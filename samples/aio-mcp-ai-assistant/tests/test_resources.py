import asyncio
import json

import httpx
import pytest

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.resources import KubernetesClient, ResourceTools, summarize


def asset():
    return {
        "kind": "Asset",
        "metadata": {
            "name": "camera-01",
            "namespace": "azure-iot-operations",
            "annotations": {"connection": "private-value"},
        },
        "spec": {
            "displayName": "Camera 01",
            "enabled": True,
            "deviceRef": {
                "deviceName": "rtsp-camera",
                "inboundEndpointName": "media",
                "connectionString": "private-value",
            },
            "datasets": [
                {"name": "person-results", "configuration": '{"password":"private-value"}'}
            ],
            "credentials": {"password": "private-value"},
        },
    }


def test_ignite_resource_envelope_redacts_secrets_and_embedded_configuration():
    value = summarize(asset())
    assert value["metadata"]["name"] == "camera-01"
    assert value["spec"]["deviceRef"] == {
        "deviceName": "rtsp-camera",
        "inboundEndpointName": "media",
        "connectionString": "[REDACTED]",
    }
    assert json.loads(value["spec"]["datasets"][0]["configuration"]) == {"password": "[REDACTED]"}
    assert "private-value" not in json.dumps(value)
    assert "annotations" not in value["metadata"]


def test_resource_list_bounds_filtered_results_and_rejects_api_failures(settings, tmp_path):
    token = tmp_path / "token"
    token.write_text("test-api-token")
    requests = []

    def respond(request):
        requests.append(request)
        if len(requests) == 1:
            other = asset()
            other["metadata"]["name"] = "camera-02"
            return httpx.Response(200, json={"items": [asset(), other], "metadata": {}})
        return httpx.Response(403, json={"message": "Forbidden"})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as http:
            tools = ResourceTools(KubernetesClient(http, token_path=token), settings)
            result = await tools.call("list_assets", {"limit": 1})
            assert result["truncated"] is True
            assert result["count"] == 1
            with pytest.raises(SampleError, match="HTTP 403"):
                await tools.call("list_assets", {"limit": 2})

    asyncio.run(run())
    assert requests[0].url.path == (
        "/apis/namespaces.deviceregistry.microsoft.com/v1/namespaces/azure-iot-operations/assets"
    )
    assert not requests[0].url.query


def test_name_prefix_is_applied_before_the_result_limit(settings, tmp_path):
    token = tmp_path / "token"
    token.write_text("test-api-token")
    other = asset()
    other["metadata"]["name"] = "motor-01"

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(200, json={"items": [other, asset()], "metadata": {}})
            )
        ) as http:
            tools = ResourceTools(KubernetesClient(http, token_path=token), settings)
            result = await tools.call("list_assets", {"limit": 1, "name_prefix": "camera"})
            assert result["items"][0]["metadata"]["name"] == "camera-01"
            assert result["truncated"] is False

    asyncio.run(run())


@pytest.mark.parametrize(
    "authenticated, audience, caller, expected",
    [
        (True, "edge-resource-mcp", "edge-assistant", True),
        (False, "edge-resource-mcp", "edge-assistant", False),
        (True, "aio-internal", "edge-assistant", False),
        (True, "edge-resource-mcp", "another-client", False),
    ],
)
def test_token_review_enforces_both_identity_and_audience(
    settings,
    tmp_path,
    authenticated,
    audience,
    caller,
    expected,
):
    token = tmp_path / "token"
    token.write_text("test-api-token")
    requests = []

    def respond(request):
        requests.append(json.loads(request.content))
        return httpx.Response(
            201,
            json={
                "status": {
                    "authenticated": authenticated,
                    "audiences": [audience],
                    "user": {"username": f"system:serviceaccount:{settings.namespace}:{caller}"},
                }
            },
        )

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as http:
            kube = KubernetesClient(http, token_path=token)
            assert await kube.authenticate("test-caller-token", settings) is expected

    asyncio.run(run())
    assert requests[0]["spec"]["audiences"] == ["edge-resource-mcp"]


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://model.example.test",
        "https://user:pass@model.example.test",
        "https://model.example.test?token=x",
        "https://model.example.test:invalid",
    ],
)
def test_model_endpoint_must_be_https_without_embedded_credentials(settings, tmp_path, endpoint):
    token = tmp_path / "token"
    token.write_text("test-api-token")

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(
                    200, json={"status": {"endpoints": {"internal": endpoint}}}
                )
            )
        ) as http:
            with pytest.raises(SampleError):
                await KubernetesClient(http, token_path=token).model_endpoint(settings)

    asyncio.run(run())
