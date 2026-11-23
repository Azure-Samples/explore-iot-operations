import asyncio
import json
import ssl
from pathlib import Path
from typing import Any

import httpx

JsonObject = dict[str, Any]
MAX_TOOL_BYTES = 256 * 1024
MAX_HTTP_BYTES = 2 * 1024 * 1024


class SampleError(RuntimeError):
    """An explicit configuration, transport, or inference failure."""


def _unique_pairs(pairs: list[tuple[str, Any]]) -> JsonObject:
    result: JsonObject = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"Non-finite JSON value: {value}")


def loads(value: str | bytes) -> Any:
    return json.loads(value, object_pairs_hook=_unique_pairs, parse_constant=_reject_constant)


def encode(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":"))


def bounded_result(value: JsonObject) -> JsonObject:
    if len(encode(value).encode()) > MAX_TOOL_BYTES:
        raise SampleError("Tool result exceeds 256 KiB; request fewer resources or messages")
    return value


async def token_from(path: Path) -> str:
    token = (await asyncio.to_thread(path.read_text, encoding="utf-8")).strip()
    if not token or len(token) > 16 * 1024 or any(character.isspace() for character in token):
        raise SampleError(f"Missing or invalid projected token at {path}")
    return token


def tls_context(path: Path) -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=str(path))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


async def response_object(response: httpx.Response, *, limit: int = MAX_HTTP_BYTES) -> JsonObject:
    body = bytearray()
    async for chunk in response.aiter_bytes():
        body.extend(chunk)
        if len(body) > limit:
            raise SampleError("HTTP response exceeds the configured size limit")
    try:
        result = loads(bytes(body))
    except (ValueError, UnicodeDecodeError) as error:
        raise SampleError("HTTP response is not valid JSON") from error
    if not isinstance(result, dict):
        raise SampleError("HTTP response must contain a JSON object")
    return result
