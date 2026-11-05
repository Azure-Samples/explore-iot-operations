import asyncio
import json
import ssl
from contextlib import asynccontextmanager
from types import SimpleNamespace

import httpx
import pytest

from aio_mcp_ai_assistant import mcp_transport
from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.mcp_transport import McpClient


@pytest.fixture
def frontend(settings, tmp_path, monkeypatch):
    token = tmp_path / "token"
    token.write_text("test-frontend-token")
    requests = []
    result = {"structuredContent": {}, "content": []}
    tools = [{"name": "aio_list_assets", "inputSchema": {"type": "object"}}]

    def respond(request):
        requests.append(request)
        if request.method == "GET":
            return httpx.Response(405)
        if request.method == "DELETE":
            return httpx.Response(200)
        body = json.loads(request.content)
        if "id" not in body:
            return httpx.Response(202)
        method = body["method"]
        if method == "initialize":
            payload = {
                "protocolVersion": body["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "frontend-fixture", "version": "0"},
            }
        elif method == "tools/list":
            payload = {"tools": tools}
            if not body.get("params", {}).get("cursor"):
                payload["nextCursor"] = "second-page"
            else:
                payload["tools"] = [{"name": "extra_builtin", "inputSchema": {"type": "object"}}]
        else:
            payload = result
        response = {"jsonrpc": "2.0", "id": body["id"], "result": payload}
        return httpx.Response(
            200,
            headers={"Content-Type": "text/event-stream", "Mcp-Session-Id": "fixture-session"},
            content="event: message\ndata: " + json.dumps(response) + "\n\n",
        )

    monkeypatch.setattr(mcp_transport, "tls_context", lambda _: ssl.create_default_context())
    monkeypatch.setattr(httpx, "AsyncHTTPTransport", lambda **_: httpx.MockTransport(respond))
    client = McpClient(settings.mcp_url, ca_path=tmp_path / "ca", token_path=token)
    return client, requests, result, token


def test_sdk_initialization_sse_pagination_and_token_refresh(frontend):
    client, requests, result, token = frontend

    async def run():
        assert [tool["name"] for tool in await client.list_tools()] == [
            "aio_list_assets",
            "extra_builtin",
        ]
        token.write_text("rotated-test-token")
        result["structuredContent"] = {"camera": "Synthetic resource fixture"}
        assert await client.call_tool("aio_list_assets", {}) == result["structuredContent"]

    asyncio.run(run())
    posts = [request for request in requests if request.method == "POST"]
    assert posts[0].headers["Authorization"] == "Bearer test-frontend-token"
    assert posts[-1].headers["Authorization"] == "Bearer rotated-test-token"
    assert any(request.headers.get("Mcp-Session-Id") == "fixture-session" for request in posts)


@pytest.mark.parametrize("structured", [True, False])
def test_accepts_builtin_structured_or_text_json(frontend, structured):
    client, _, result, _ = frontend
    result.clear()
    if structured:
        result.update({"structuredContent": {"messages": []}, "content": []})
    else:
        result["content"] = [{"type": "text", "text": '{"messages":[]}'}]
    assert asyncio.run(client.call_tool("aio_mq_messages", {})) == {"messages": []}


@pytest.mark.parametrize(
    "result",
    [
        {"isError": True, "content": [{"type": "text", "text": "Forbidden"}]},
        {"content": [{"type": "text", "text": "not JSON"}]},
        {"content": [{"type": "text", "text": "[]"}]},
        {"content": [{"type": "text", "text": '{"x":1,"x":2}'}]},
        {"content": []},
        {"content": [{"type": "text", "text": "x" * (600 * 1024)}]},
    ],
)
def test_mcp_failures_never_become_empty_success(frontend, result):
    client, _, response, _ = frontend
    response.clear()
    response.update(result)
    with pytest.raises(SampleError):
        asyncio.run(client.call_tool("aio_mqtt_publish", {}))


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://127.0.0.1:8081/mcp",
        "https://edge-resource-mcp.sample.svc.cluster.local/mcp",
        "https://aio-mcp.azure-iot-operations.svc/mcp",
        "https://aio-mcp-frontend.azure-iot-operations.svc/mcp?token=unsafe",
        "https://aio-mcp-frontend.azure-iot-operations.svc:8443/mcp",
        "https://aio-mcp-frontend.azure-iot-operations.svc/other",
    ],
)
def test_only_builtin_frontend_is_accepted(endpoint, tmp_path):
    with pytest.raises(ValueError):
        McpClient(endpoint, ca_path=tmp_path / "ca", token_path=tmp_path / "token")


@pytest.mark.parametrize(
    "cursors, message",
    [
        ([""], "pagination cursor"),
        (["same", "same"], "pagination cursor"),
        ([str(page) for page in range(256)], "256 pages"),
    ],
)
def test_catalog_cannot_loop_over_empty_or_repeated_pages(frontend, monkeypatch, cursors, message):
    client, _, _, _ = frontend
    pages = iter(cursors)

    class Session:
        async def list_tools(self, cursor):
            return SimpleNamespace(tools=[], nextCursor=next(pages))

    @asynccontextmanager
    async def session():
        yield Session()

    monkeypatch.setattr(client, "session", session)
    with pytest.raises(SampleError, match=message):
        asyncio.run(client.list_tools())
