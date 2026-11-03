import re
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

import httpx

from .common import (
    JsonObject,
    SampleError,
    bounded_result,
    encode,
    loads,
    response_object,
    token_from,
)
from .config import KUBE_TOKEN, RESOURCE_AUDIENCE, Settings
from .tools import catalog, checked_tool

_SENSITIVE_KEYS = re.compile(
    r"(?:password|passwd|token|secret|credential|certificate|private.?key|api.?key|"
    r"connection.?string|^key$)",
    re.IGNORECASE,
)


class KubernetesClient:
    def __init__(
        self,
        client: httpx.AsyncClient,
        *,
        token_path: Path = KUBE_TOKEN,
        api_server: str = "https://kubernetes.default.svc",
    ) -> None:
        self.client = client
        self.token_path = token_path
        self.api_server = api_server

    async def request(
        self, method: str, path: str, *, body: JsonObject | None = None, status: int = 200
    ) -> JsonObject:
        token = await token_from(self.token_path)
        async with self.client.stream(
            method,
            self.api_server + path,
            headers={"Authorization": "Bearer " + token},
            json=body,
            timeout=10,
        ) as response:
            if response.status_code != status:
                raise SampleError(f"Kubernetes {method} failed with HTTP {response.status_code}")
            return await response_object(response)

    async def authenticate(self, caller_token: str, settings: Settings) -> bool:
        payload = await self.request(
            "POST",
            "/apis/authentication.k8s.io/v1/tokenreviews",
            status=201,
            body={
                "apiVersion": "authentication.k8s.io/v1",
                "kind": "TokenReview",
                "spec": {"token": caller_token, "audiences": [RESOURCE_AUDIENCE]},
            },
        )
        status = payload.get("status")
        if not isinstance(status, dict):
            raise SampleError("TokenReview returned an invalid status")
        user = status.get("user")
        audiences = status.get("audiences")
        return (
            status.get("authenticated") is True
            and isinstance(audiences, list)
            and RESOURCE_AUDIENCE in audiences
            and isinstance(user, dict)
            and user.get("username") == f"system:serviceaccount:{settings.namespace}:edge-assistant"
        )

    async def model_endpoint(self, settings: Settings) -> str:
        namespace = quote(settings.foundry.namespace, safe="")
        name = quote(settings.foundry.deployment_name, safe="")
        payload = await self.request(
            "GET", f"/apis/foundrylocal.azure.com/v1/namespaces/{namespace}/modeldeployments/{name}"
        )
        status = payload.get("status")
        endpoints = status.get("endpoints") if isinstance(status, dict) else None
        endpoint = endpoints.get("internal") if isinstance(endpoints, dict) else None
        if not isinstance(endpoint, str):
            raise SampleError("ModelDeployment has no status.endpoints.internal URL")
        url = urlsplit(endpoint)
        try:
            valid_port = url.port is None or 1 <= url.port <= 65535
        except ValueError as error:
            raise SampleError("ModelDeployment returned an invalid port") from error
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
            or not valid_port
        ):
            raise SampleError("ModelDeployment must provide an HTTPS base URL without credentials")
        return endpoint.rstrip("/")


class ResourceTools:
    def __init__(self, client: KubernetesClient, settings: Settings) -> None:
        self.client = client
        self.namespace = settings.aio_namespace

    async def call(self, name: str, arguments: JsonObject) -> JsonObject:
        checked_tool(
            {name: tool for name, tool in catalog().items() if tool.source == "resources"},
            name,
            arguments,
        )
        plural = {
            "list_assets": "assets",
            "get_asset": "assets",
            "list_devices": "devices",
            "get_device": "devices",
        }[name]
        base = (
            "/apis/namespaces.deviceregistry.microsoft.com/v1/namespaces/"
            f"{quote(self.namespace, safe='')}/{plural}"
        )
        if name.startswith("get_"):
            resource = await self.client.request(
                "GET", base + "/" + quote(arguments["name"], safe="")
            )
            return bounded_result({"item": summarize(resource)})
        limit = arguments.get("limit", 20)
        prefix = arguments.get("name_prefix")
        payload = await self.client.request("GET", base)
        items = payload.get("items")
        metadata = payload.get("metadata", {})
        if (
            not isinstance(items, list)
            or any(not isinstance(item, dict) for item in items)
            or not isinstance(metadata, dict)
        ):
            raise SampleError("Kubernetes returned an invalid resource list")
        continuation = metadata.get("continue", "")
        if not isinstance(continuation, str):
            raise SampleError("Kubernetes returned an invalid continuation indicator")
        sanitized = [summarize(item) for item in items]
        filtered = [
            item
            for item in sanitized
            if prefix is None or item["metadata"]["name"].startswith(prefix)
        ]
        return bounded_result(
            {
                "items": filtered[:limit],
                "count": min(len(filtered), limit),
                "truncated": len(filtered) > limit or bool(continuation),
            }
        )


def summarize(resource: JsonObject) -> JsonObject:
    metadata = resource.get("metadata")
    spec = resource.get("spec", {})
    if not isinstance(metadata, dict) or not isinstance(spec, dict):
        raise SampleError("Resource has an invalid metadata/spec structure")
    if not isinstance(metadata.get("name"), str):
        raise SampleError("Resource has no valid name")
    result: JsonObject = {
        "apiVersion": resource.get("apiVersion"),
        "kind": resource.get("kind"),
        "metadata": {
            key: redact(metadata[key])
            for key in ("name", "namespace", "labels", "creationTimestamp")
            if key in metadata
        },
    }
    for key in ("spec", "status"):
        if key in resource:
            result[key] = redact(resource[key])
    return result


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if _SENSITIVE_KEYS.search(key) else redact(child)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, str):
        if value.startswith(("{", "[")):
            try:
                nested = loads(value)
            except ValueError as error:
                raise SampleError("Resource contains invalid JSON configuration") from error
            if isinstance(nested, (dict, list)):
                return encode(redact(nested))
        if len(value) > 4096:
            raise SampleError("Resource string exceeds 4096 characters")
    return value
