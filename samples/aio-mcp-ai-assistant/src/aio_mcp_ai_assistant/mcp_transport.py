import asyncio
import logging
import sys
from contextlib import AsyncExitStack, asynccontextmanager
from datetime import timedelta
from pathlib import Path
from typing import Literal, Protocol

import aiomqtt
import anyio
import httpx
from mcp import ClientSession, types
from mcp.client.streamable_http import streamable_http_client
from mcp.server.lowlevel import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from mcp.shared.exceptions import McpError
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route
from starlette.types import Receive, Scope, Send

from .common import JsonObject, SampleError, bounded_result, encode, tls_context, token_from
from .config import (
    BROKER_CA,
    KUBE_CA,
    RESOURCE_CA,
    RESOURCE_TOKEN,
    RESOURCES,
    Settings,
)
from .mqtt import MqttTools
from .resources import KubernetesClient, ResourceTools
from .tools import catalog, checked_tool

if sys.version_info >= (3, 11):
    from builtins import ExceptionGroup
else:
    from exceptiongroup import ExceptionGroup

LOGGER = logging.getLogger(__name__)
TRANSPORT_ERRORS = (
    httpx.HTTPError,
    McpError,
    anyio.BrokenResourceError,
    anyio.ClosedResourceError,
    anyio.EndOfStream,
    OSError,
    ValueError,
    asyncio.TimeoutError,
)


class ToolBackend(Protocol):
    async def call(self, name: str, arguments: JsonObject) -> JsonObject: ...


class TokenReviewer(Protocol):
    async def authenticate(self, token: str, settings: Settings) -> bool: ...


class McpClient:
    def __init__(
        self, endpoint: str, *, ca_path: Path | None = None, token_path: Path | None = None
    ) -> None:
        if endpoint.startswith("https://"):
            if ca_path is None or token_path is None:
                raise ValueError("Remote resource MCP requires TLS trust and a projected token")
        elif endpoint != "http://127.0.0.1:8081/mcp" or ca_path or token_path:
            raise ValueError("Unauthenticated MCP is restricted to the MQTT sidecar's loopback URL")
        self.endpoint = endpoint
        self.ca_path = ca_path
        self.token_path = token_path

    @asynccontextmanager
    async def session(self):
        headers = {}
        if self.token_path is not None:
            headers["Authorization"] = "Bearer " + await token_from(self.token_path)
        timeout = 120 if self.endpoint == "http://127.0.0.1:8081/mcp" else 30
        try:
            async with httpx.AsyncClient(
                verify=tls_context(self.ca_path) if self.ca_path else True,
                headers=headers,
                timeout=httpx.Timeout(timeout, connect=5),
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with streamable_http_client(self.endpoint, http_client=client) as (
                    read,
                    write,
                    _,
                ):
                    async with ClientSession(
                        read, write, read_timeout_seconds=timedelta(seconds=timeout)
                    ) as session:
                        await session.initialize()
                        yield session
        except TRANSPORT_ERRORS as error:
            raise SampleError(f"MCP transport failed: {error}") from error
        except ExceptionGroup as error:
            _, unexpected = error.split(TRANSPORT_ERRORS)
            if unexpected is not None:
                raise
            LOGGER.error("MCP transport failed at %s", self.endpoint, exc_info=True)
            raise SampleError("MCP transport failed; inspect agent logs for the cause") from error

    async def list_tools(self) -> list[JsonObject]:
        async with self.session() as session:
            response = await session.list_tools()
        if response.nextCursor is not None:
            raise SampleError("MCP tool catalog unexpectedly requires pagination")
        return [{"name": tool.name, "inputSchema": tool.inputSchema} for tool in response.tools]

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject:
        async with self.session() as session:
            response = await session.call_tool(name, arguments)
        if response.isError:
            raise SampleError(f"MCP tool {name} failed; inspect the corresponding MCP service logs")
        if not isinstance(response.structuredContent, dict):
            raise SampleError("MCP tool did not return the expected structured JSON result")
        return bounded_result(response.structuredContent)


def clients(settings: Settings) -> dict[str, McpClient]:
    return {
        "resources": McpClient(
            settings.resource_url, ca_path=RESOURCE_CA, token_path=RESOURCE_TOKEN
        ),
        "mqtt": McpClient("http://127.0.0.1:8081/mcp"),
    }


class McpEndpoint:
    def __init__(
        self,
        manager: StreamableHTTPSessionManager,
        kind: Literal["resources", "mqtt"],
        settings: Settings,
    ) -> None:
        self.manager = manager
        self.kind = kind
        self.settings = settings

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        request = Request(scope, receive)
        if self.kind == "resources":
            header = request.headers.get("authorization", "")
            scheme, _, token = header.partition(" ")
            if scheme.lower() != "bearer" or not token or len(token) > 16 * 1024:
                await JSONResponse({"error": "A projected bearer token is required"}, 401)(
                    scope, receive, send
                )
                return
            reviewer: TokenReviewer = request.app.state.reviewer
            try:
                authorized = await reviewer.authenticate(token, self.settings)
            except (SampleError, OSError, httpx.HTTPError) as error:
                LOGGER.error("MCP TokenReview failed: %s", error)
                await JSONResponse({"error": "Token validation is unavailable"}, 503)(
                    scope, receive, send
                )
                return
            if not authorized:
                LOGGER.warning("Resource MCP rejected an unauthorized caller")
                await JSONResponse({"error": "Caller is not authorized for this MCP service"}, 403)(
                    scope, receive, send
                )
                return
        await self.manager.handle_request(scope, receive, send)


def create_mcp_app(
    settings: Settings,
    kind: Literal["resources", "mqtt"],
    *,
    backend: ToolBackend | None = None,
    reviewer: TokenReviewer | None = None,
) -> Starlette:
    if kind not in {"resources", "mqtt"}:
        raise ValueError("Unknown MCP service")
    tools = {tool.remote_name: tool for tool in catalog().values() if tool.source == kind}
    server = Server(f"edge-{kind}-mcp", version="0.1.0")

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return [
            types.Tool(
                name=tool.remote_name,
                description=tool.description,
                inputSchema=tool.schema,
                annotations=types.ToolAnnotations(
                    readOnlyHint=tool.read_only,
                    destructiveHint=not tool.read_only,
                    idempotentHint=tool.read_only,
                ),
            )
            for tool in tools.values()
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: JsonObject) -> types.CallToolResult:
        try:
            checked_tool(tools, name, arguments)
            handler: ToolBackend = app.state.backend
            result = bounded_result(await handler.call(name, arguments))
        except (SampleError, ValueError, OSError, httpx.HTTPError, aiomqtt.MqttError) as error:
            LOGGER.error("MCP tool %s failed: %s", name, error)
            return types.CallToolResult(
                isError=True,
                content=[types.TextContent(type="text", text=encode({"error": str(error)}))],
            )
        return types.CallToolResult(
            content=[types.TextContent(type="text", text=encode(result))],
            structuredContent=result,
        )

    host = f"{RESOURCES}.{settings.namespace}.svc.cluster.local"
    manager = StreamableHTTPSessionManager(
        server,
        stateless=True,
        json_response=True,
        max_request_body_size=16 * 1024,
        security_settings=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=[host, f"{host}:443"] if kind == "resources" else ["127.0.0.1:8081"],
            allowed_origins=[],
        ),
    )

    @asynccontextmanager
    async def lifespan(application: Starlette):
        async with AsyncExitStack() as stack:
            kube = None
            if kind == "resources" and (backend is None or reviewer is None):
                http = await stack.enter_async_context(
                    httpx.AsyncClient(verify=tls_context(KUBE_CA), trust_env=False)
                )
                kube = KubernetesClient(http)
            if backend is not None:
                application.state.backend = backend
            elif kind == "resources":
                if kube is None:
                    raise RuntimeError("Resource MCP requires a Kubernetes client")
                application.state.backend = ResourceTools(kube, settings)
            else:
                application.state.backend = MqttTools(settings, tls_context(BROKER_CA))
            application.state.reviewer = reviewer if reviewer is not None else kube
            await stack.enter_async_context(manager.run())
            yield

    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "configured", "service": kind})

    app = Starlette(
        lifespan=lifespan,
        routes=[
            Route("/mcp", McpEndpoint(manager, kind, settings), methods=["POST", "GET", "DELETE"]),
            Route("/healthz", health),
            Route("/readyz", health),
        ],
    )
    return app
