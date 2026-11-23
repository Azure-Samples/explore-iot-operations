import asyncio
import logging
import re
import sys
from contextlib import asynccontextmanager
from datetime import timedelta
from pathlib import Path
from urllib.parse import urlsplit

import anyio
import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.exceptions import McpError

from .common import JsonObject, SampleError, bounded_result, loads, tls_context, token_from

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
    SampleError,
)


class BoundedStream(httpx.AsyncByteStream):
    def __init__(self, stream: httpx.AsyncByteStream) -> None:
        self.stream = stream

    async def __aiter__(self):
        size = 0
        async for chunk in self.stream:
            size += len(chunk)
            if size > 512 * 1024:
                raise SampleError("MCP response exceeds 512 KiB")
            yield chunk

    async def aclose(self) -> None:
        await self.stream.aclose()


class BoundedTransport(httpx.AsyncBaseTransport):
    def __init__(self, transport: httpx.AsyncBaseTransport) -> None:
        self.transport = transport

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        response = await self.transport.handle_async_request(request)
        if not isinstance(response.stream, httpx.AsyncByteStream):
            raise SampleError("MCP transport must return an asynchronous response stream")
        response.stream = BoundedStream(response.stream)
        return response

    async def aclose(self) -> None:
        await self.transport.aclose()


class McpClient:
    def __init__(self, endpoint: str, *, ca_path: Path, token_path: Path) -> None:
        url = urlsplit(endpoint)
        if (
            url.scheme != "https"
            or re.fullmatch(
                r"aio-mcp-frontend\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
                r"\.svc(?:\.cluster\.local)?",
                url.hostname or "",
            )
            is None
            or url.port not in (None, 443)
            or url.path != "/mcp"
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
        ):
            raise ValueError("Use the built-in AIO MCP frontend's HTTPS /mcp endpoint")
        self.endpoint = endpoint
        self.ca_path = ca_path
        self.token_path = token_path

    @asynccontextmanager
    async def session(self):
        try:
            token = await token_from(self.token_path)
            transport = BoundedTransport(
                httpx.AsyncHTTPTransport(verify=tls_context(self.ca_path), trust_env=False)
            )
            async with httpx.AsyncClient(
                transport=transport,
                headers={"Authorization": "Bearer " + token},
                timeout=httpx.Timeout(75, connect=5),
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with streamable_http_client(self.endpoint, http_client=client) as (
                    read,
                    write,
                    _,
                ):
                    async with ClientSession(
                        read, write, read_timeout_seconds=timedelta(seconds=75)
                    ) as session:
                        await session.initialize()
                        yield session
        except TRANSPORT_ERRORS as error:
            raise SampleError(f"MCP frontend request failed: {error}") from error
        except ExceptionGroup as error:
            _, unexpected = error.split(TRANSPORT_ERRORS)
            if unexpected is not None:
                raise
            LOGGER.error("MCP frontend request failed at %s", self.endpoint, exc_info=True)
            raise SampleError("MCP frontend request failed; inspect agent logs") from error

    async def list_tools(self) -> list[JsonObject]:
        tools = []
        seen: set[str] = set()
        cursor = None
        async with self.session() as session:
            for _ in range(256):
                response = await session.list_tools(cursor=cursor)
                tools.extend(
                    {"name": tool.name, "inputSchema": tool.inputSchema} for tool in response.tools
                )
                if len(tools) > 256:
                    raise SampleError("MCP catalog exceeds 256 tools")
                cursor = response.nextCursor
                if cursor is None:
                    return tools
                if not cursor or cursor in seen:
                    raise SampleError("MCP catalog returned an invalid pagination cursor")
                seen.add(cursor)
            raise SampleError("MCP catalog exceeds 256 pages")

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject:
        async with self.session() as session:
            response = await session.call_tool(name, arguments)
        if response.isError:
            raise SampleError(f"Built-in MCP tool {name} reported an error; inspect AIO MCP logs")
        if isinstance(response.structuredContent, dict):
            return bounded_result(response.structuredContent)
        if len(response.content) != 1 or response.content[0].type != "text":
            raise SampleError("MCP tool must return structured JSON or one JSON text item")
        try:
            result = loads(response.content[0].text)
        except (ValueError, UnicodeDecodeError) as error:
            raise SampleError("MCP tool returned invalid JSON") from error
        if not isinstance(result, dict):
            raise SampleError("MCP tool result must be a JSON object")
        return bounded_result(result)
