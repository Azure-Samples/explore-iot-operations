import logging
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass
from pathlib import Path

import httpx

from .common import JsonObject, SampleError, loads, token_from
from .config import FOUNDRY_TOKEN, Settings
from .kubernetes import KubernetesClient

MAX_COMPLETION_BYTES = 1024 * 1024
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class Completion:
    content: str
    finish_reasons: tuple[str, ...] = ()


async def sse_data(chunks: AsyncIterable[bytes]) -> AsyncIterator[str]:
    buffer = b""
    parts: list[str] = []
    total = 0
    async for chunk in chunks:
        total += len(chunk)
        if total > MAX_COMPLETION_BYTES:
            raise SampleError("Foundry response exceeds 1 MiB")
        buffer += chunk
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            try:
                line = raw.rstrip(b"\r").decode("utf-8")
            except UnicodeDecodeError as error:
                raise SampleError("Foundry returned invalid UTF-8") from error
            if not line:
                if parts:
                    yield "\n".join(parts)
                    parts = []
            elif line.startswith("data:"):
                parts.append(line[5:].lstrip(" "))
            elif line.startswith(":") or line.startswith("event:"):
                continue
            else:
                raise SampleError("Foundry returned an unsupported streaming event")
    if buffer or parts:
        raise SampleError("Foundry stream ended within an incomplete event")


async def read_completion(chunks: AsyncIterable[bytes]) -> Completion:
    content: list[str] = []
    finish_reasons: list[str] = []
    completed = False
    async for event in sse_data(chunks):
        if event == "[DONE]":
            completed = True
            break
        try:
            payload = loads(event)
        except ValueError as error:
            raise SampleError("Foundry returned invalid streaming JSON") from error
        choices = payload.get("choices") if isinstance(payload, dict) else None
        if choices == [] and isinstance(payload.get("usage"), dict):
            continue
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise SampleError("Foundry returned an invalid completion choice")
        choice = choices[0]
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            raise SampleError("Foundry returned an invalid streaming delta")
        text = delta.get("content")
        if text is not None:
            if not isinstance(text, str):
                raise SampleError("Foundry returned invalid text content")
            content.append(text)
        if choice.get("finish_reason") is not None:
            reason = choice["finish_reason"]
            if not isinstance(reason, str):
                raise SampleError("Foundry returned an invalid finish reason")
            finish_reasons.append(reason)
            if reason not in {"stop", "tool_calls"}:
                LOGGER.warning("Foundry completion finish reason: %s", reason)
    if not completed:
        raise SampleError("Foundry streaming response ended before completion")
    text = "".join(content)
    if not text.strip():
        raise SampleError("Foundry returned empty assistant content")
    return Completion(text, tuple(finish_reasons))


class FoundryClient:
    def __init__(
        self,
        settings: Settings,
        kube: KubernetesClient,
        client: httpx.AsyncClient,
        *,
        token_path: Path = FOUNDRY_TOKEN,
    ) -> None:
        self.settings = settings
        self.kube = kube
        self.client = client
        self.token_path = token_path

    async def complete(self, messages: list[JsonObject], tools: list[JsonObject]) -> Completion:
        endpoint = await self.kube.model_endpoint(self.settings)
        token = await token_from(self.token_path)
        async with self.client.stream(
            "POST",
            endpoint + "/v1/chat/completions",
            headers={"Authorization": "Bearer " + token},
            json={
                "model": self.settings.model_id,
                "messages": messages,
                "tools": tools,
                "tool_choice": "auto",
                "temperature": 0,
                "max_tokens": 256,
                "stream": True,
            },
            timeout=httpx.Timeout(300, connect=10),
        ) as response:
            if response.status_code != 200:
                raise SampleError(f"Foundry inference failed with HTTP {response.status_code}")
            if response.headers.get("content-type", "").split(";")[0] != "text/event-stream":
                raise SampleError("Foundry must return an OpenAI-compatible SSE response")
            return await read_completion(response.aiter_bytes())
