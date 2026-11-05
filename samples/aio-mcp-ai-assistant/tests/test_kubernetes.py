import asyncio

import httpx
import pytest

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.kubernetes import KubernetesClient


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://model.example.test",
        "https://user:password@model.example.test",
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
