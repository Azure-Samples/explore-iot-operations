from pathlib import Path
from urllib.parse import quote, urlsplit

import httpx

from .common import JsonObject, SampleError, response_object, token_from
from .config import KUBE_TOKEN, Settings


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
