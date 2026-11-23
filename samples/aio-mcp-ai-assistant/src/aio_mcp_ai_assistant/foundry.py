import logging
from dataclasses import dataclass
from pathlib import Path

import httpx

from .common import JsonObject, SampleError, response_object, token_from
from .config import FOUNDRY_TOKEN, Settings
from .kubernetes import KubernetesClient

MAX_COMPLETION_BYTES = 1024 * 1024
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class Completion:
    content: str
    finish_reasons: tuple[str, ...] = ()


async def read_completion(response: httpx.Response) -> Completion:
    payload = await response_object(response, limit=MAX_COMPLETION_BYTES)
    choices = payload.get("choices")
    if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
        raise SampleError("Foundry returned an invalid completion choice")
    choice = choices[0]
    if type(choice.get("index")) is not int or choice["index"] != 0:
        raise SampleError("Foundry returned an invalid completion index")
    message = choice.get("message")
    if not isinstance(message, dict):
        raise SampleError("Foundry returned an invalid assistant message")
    text = message.get("content")
    if not isinstance(text, str) or not text.strip():
        raise SampleError("Foundry returned empty assistant content")
    reason = choice.get("finish_reason")
    if not isinstance(reason, str) or not reason:
        raise SampleError("Foundry returned an invalid finish reason")
    if reason not in {"stop", "tool_calls"}:
        LOGGER.warning("Foundry completion finish reason: %s", reason)
    return Completion(text, (reason,))


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
            headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
            json={
                "model": self.settings.model_id,
                "messages": messages,
                "tools": tools,
                "tool_choice": "auto",
                "temperature": 0,
                "max_tokens": 256,
                "stream": False,
            },
            timeout=httpx.Timeout(300, connect=10),
        ) as response:
            if response.status_code != 200:
                raise SampleError(f"Foundry inference failed with HTTP {response.status_code}")
            if (
                response.headers.get("content-type", "").split(";")[0].strip().lower()
                != "application/json"
            ):
                raise SampleError("Foundry must return an OpenAI-compatible JSON response")
            return await read_completion(response)
