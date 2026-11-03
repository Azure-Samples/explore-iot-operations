import asyncio
import logging
from contextlib import AsyncExitStack, asynccontextmanager

import httpx
from mcp.shared.exceptions import McpError
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .common import SampleError, loads, tls_context
from .config import FOUNDRY_CA, KUBE_CA, Settings
from .foundry import FoundryClient
from .mcp_transport import clients
from .resources import KubernetesClient
from .runtime import AgentBusy, Runtime

LOGGER = logging.getLogger(__name__)


def create_agent_app(settings: Settings) -> Starlette:
    @asynccontextmanager
    async def lifespan(app: Starlette):
        async with AsyncExitStack() as stack:
            kube_http = await stack.enter_async_context(
                httpx.AsyncClient(verify=tls_context(KUBE_CA), trust_env=False)
            )
            foundry_http = await stack.enter_async_context(
                httpx.AsyncClient(verify=tls_context(FOUNDRY_CA), trust_env=False)
            )
            app.state.kube = KubernetesClient(kube_http)
            app.state.runtime = Runtime(
                settings,
                FoundryClient(settings, app.state.kube, foundry_http),
                clients(settings),
            )
            yield

    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "running"})

    async def ready(request: Request) -> JSONResponse:
        runtime: Runtime = request.app.state.runtime
        tools = await asyncio.wait_for(runtime.discover(), timeout=20)
        endpoint = await request.app.state.kube.model_endpoint(settings)
        return JSONResponse(
            {
                "status": "ready",
                **tools,
                "model": settings.model_id,
                "modelEndpoint": endpoint,
                "modelInferenceVerified": False,
                "mqttSubscriptionVerified": False,
            }
        )

    async def chat(request: Request) -> JSONResponse:
        payload = loads(await request.body())
        if not isinstance(payload, dict) or set(payload) != {"question"}:
            raise ValueError("Expected a JSON object containing only question")
        runtime: Runtime = request.app.state.runtime
        return JSONResponse(await runtime.ask(payload["question"]))

    async def tool(request: Request) -> JSONResponse:
        payload = loads(await request.body())
        if (
            not isinstance(payload, dict)
            or set(payload) != {"name", "arguments"}
            or not isinstance(payload["name"], str)
            or not isinstance(payload["arguments"], dict)
        ):
            raise ValueError("Expected a tool name and arguments object")
        runtime: Runtime = request.app.state.runtime
        await runtime.discover()
        return JSONResponse(await runtime.call_tool(payload["name"], payload["arguments"]))

    async def approval(request: Request) -> JSONResponse:
        payload = loads(await request.body())
        if (
            not isinstance(payload, dict)
            or set(payload) != {"id", "decision"}
            or not isinstance(payload["id"], str)
            or not 1 <= len(payload["id"]) <= 128
            or payload["decision"] not in ("approve", "deny")
        ):
            raise ValueError("Expected an approval id and a decision of approve or deny")
        runtime: Runtime = request.app.state.runtime
        return JSONResponse(await runtime.decide_approval(payload["id"], payload["decision"]))

    async def failure(_: Request, error: Exception) -> JSONResponse:
        status = (
            409 if isinstance(error, AgentBusy) else 400 if isinstance(error, ValueError) else 502
        )
        LOGGER.error("Assistant request failed: %s", error)
        return JSONResponse({"status": "error", "error": str(error)}, status_code=status)

    return Starlette(
        lifespan=lifespan,
        routes=[
            Route("/healthz", health),
            Route("/readyz", ready),
            Route("/chat", chat, methods=["POST"], max_body_size=20 * 1024),
            Route("/tool", tool, methods=["POST"], max_body_size=16 * 1024),
            Route("/approval", approval, methods=["POST"], max_body_size=1024),
        ],
        exception_handlers={
            SampleError: failure,
            ValueError: failure,
            OSError: failure,
            httpx.HTTPError: failure,
            McpError: failure,
            asyncio.TimeoutError: failure,
        },
    )
