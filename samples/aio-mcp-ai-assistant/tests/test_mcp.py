import asyncio

import httpx
import pytest
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.mcp_transport import McpClient, create_mcp_app


class Backend:
    def __init__(self):
        self.calls = []

    async def call(self, name, arguments):
        self.calls.append((name, arguments))
        if arguments.get("limit") == 2:
            raise SampleError("Explicit backend failure")
        return {"items": [], "count": 0, "truncated": False}


class Reviewer:
    async def authenticate(self, token, settings):
        return token == "test-authorized-token"


def test_official_mcp_initialization_discovery_and_tool_contracts(settings):
    backend = Backend()
    app = create_mcp_app(settings, "resources", backend=backend, reviewer=Reviewer())

    async def run():
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app),
                headers={"Authorization": "Bearer test-authorized-token"},
            ) as http:
                async with streamable_http_client(settings.resource_url, http_client=http) as (
                    read,
                    write,
                    _,
                ):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        tools = await session.list_tools()
                        assert {tool.name for tool in tools.tools} == {
                            "list_assets",
                            "get_asset",
                            "list_devices",
                            "get_device",
                        }
                        result = await session.call_tool("list_assets", {"limit": 1})
                        assert result.structuredContent == {
                            "items": [],
                            "count": 0,
                            "truncated": False,
                        }
                        assert not result.isError
                        invalid = await session.call_tool("list_assets", {"limit": 1000})
                        assert invalid.isError
                        denied = await session.call_tool("publish", {})
                        assert denied.isError
                        failure = await session.call_tool("list_assets", {"limit": 2})
                        assert failure.isError
        assert backend.calls == [("list_assets", {"limit": 1}), ("list_assets", {"limit": 2})]

    asyncio.run(run())


def test_resource_endpoint_requires_authorized_token_and_trusted_host(settings):
    app = create_mcp_app(settings, "resources", backend=Backend(), reviewer=Reviewer())

    async def run():
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app),
                base_url=settings.resource_url.removesuffix("/mcp"),
            ) as client:
                assert (await client.get("/mcp")).status_code == 401
                assert (
                    await client.get("/mcp", headers={"Authorization": "Bearer " + "wrong-token"})
                ).status_code == 403
                assert (
                    await client.get(
                        "/mcp",
                        headers={
                            "Authorization": "Bearer " + "test-authorized-token",
                            "Host": "unexpected.example",
                        },
                    )
                ).status_code == 421

    asyncio.run(run())


def test_client_surfaces_transport_errors(settings, monkeypatch):
    original = httpx.AsyncClient

    def client(**kwargs):
        return original(transport=httpx.MockTransport(lambda _: httpx.Response(503)), **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", client)
    with pytest.raises(SampleError, match="MCP"):
        asyncio.run(McpClient("http://127.0.0.1:8081/mcp").list_tools())


def test_mqtt_mcp_advertises_actions_as_writes(settings):
    app = create_mcp_app(settings, "mqtt", backend=Backend())

    async def run():
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app)) as http:
                async with streamable_http_client(
                    "http://127.0.0.1:8081/mcp", http_client=http
                ) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        response = await session.list_tools()
                        tools = {tool.name: tool for tool in response.tools}
                        assert set(tools) == {"mq_messages", "mq_camera_pan", "mq_publish"}
                        assert tools["mq_messages"].annotations.readOnlyHint is True
                        for name in ("mq_camera_pan", "mq_publish"):
                            assert tools[name].annotations.readOnlyHint is False
                            assert tools[name].annotations.destructiveHint is True

    asyncio.run(run())
