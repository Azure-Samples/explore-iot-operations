import asyncio

import httpx
from conftest import builtin_tools

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.runtime import Runtime as AgentRuntime
from aio_mcp_ai_assistant.server import create_agent_app


class Runtime:
    async def discover(self):
        return {"tools": ["list_assets"]}

    async def ask(self, question):
        raise SampleError("The evidence source is unavailable")


class Kube:
    async def model_endpoint(self, settings):
        return "https://model.example.test"


def test_readiness_does_not_claim_model_or_broker_execution(settings):
    app = create_agent_app(settings)
    app.state.runtime = Runtime()
    app.state.kube = Kube()

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://127.0.0.1:8080"
        ) as client:
            response = await client.get("/readyz")
            assert response.status_code == 200
            assert response.json()["modelInferenceVerified"] is False
            assert response.json()["mqttSubscriptionVerified"] is False

    asyncio.run(run())


def test_chat_rejects_extra_duplicate_and_oversized_input(settings):
    app = create_agent_app(settings)
    app.state.runtime = Runtime()

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://127.0.0.1:8080"
        ) as client:
            extra = await client.post("/chat", json={"question": "Read", "tools": ["publish"]})
            assert extra.status_code == 400
            duplicate = await client.post(
                "/chat",
                content=b'{"question":"Read","question":"Other"}',
                headers={"Content-Type": "application/json"},
            )
            assert duplicate.status_code == 400
            oversized = await client.post("/chat", json={"question": "x" * (20 * 1024)})
            assert oversized.status_code == 413

    asyncio.run(run())


def test_dependency_failure_is_an_explicit_http_error(settings):
    app = create_agent_app(settings)
    app.state.runtime = Runtime()

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://127.0.0.1:8080"
        ) as client:
            response = await client.post("/chat", json={"question": "Read assets"})
            assert response.status_code == 502
            assert response.json() == {
                "status": "error",
                "error": "The evidence source is unavailable",
            }

    asyncio.run(run())


def test_http_tool_cannot_bypass_publication_approval(action_settings, recommendation):
    calls = []

    class Tools:
        async def list_tools(self):
            return builtin_tools()

        async def call_tool(self, name, arguments):
            calls.append((name, arguments))
            return {"published": True}

    app = create_agent_app(action_settings)
    app.state.runtime = AgentRuntime(action_settings, Runtime(), Tools())

    async def run():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://127.0.0.1:8080"
        ) as client:
            pending = await client.post(
                "/tool", json={"name": "recommendation-publish", "arguments": recommendation}
            )
            assert pending.status_code == 200
            assert pending.json()["status"] == "approval_required"
            assert not calls
            approval_id = pending.json()["approval"]["id"]
            invalid = await client.post(
                "/approval",
                json={"id": approval_id, "decision": "approve", "arguments": recommendation},
            )
            assert invalid.status_code == 400
            assert not calls
            accepted = await client.post(
                "/approval", json={"id": approval_id, "decision": "approve"}
            )
            assert accepted.json()["status"] == "published"
            repeated = await client.post(
                "/approval", json={"id": approval_id, "decision": "approve"}
            )
            assert repeated.status_code == 400

    asyncio.run(run())
    assert calls == [("recommendation-publish", recommendation)]
