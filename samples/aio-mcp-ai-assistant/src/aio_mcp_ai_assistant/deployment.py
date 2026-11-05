import base64
import hashlib
import json
import re
import secrets
import ssl
import subprocess
from pathlib import Path
from typing import Any

import yaml

from .common import JsonObject, SampleError, encode, loads
from .config import AGENT, PART_OF, Settings

GROUPS = ("namespace", "access", "model", "workloads")


def ownership(settings: Settings) -> dict[str, str]:
    return {
        "app.kubernetes.io/part-of": PART_OF,
        "app.kubernetes.io/instance": settings.namespace,
    }


def _substitute(value: Any, variables: JsonObject) -> Any:
    if isinstance(value, dict):
        return {key: _substitute(item, variables) for key, item in value.items()}
    if isinstance(value, list):
        return [_substitute(item, variables) for item in value]
    if isinstance(value, str) and "${" in value:
        match = re.fullmatch(r"\$\{([A-Za-z]+)\}", value)
        if match is None or match[1] not in variables:
            raise SampleError(f"Unknown or partial manifest placeholder: {value}")
        return variables[match[1]]
    return value


def render(settings: Settings, template_dir: Path) -> dict[str, list[JsonObject]]:
    variables: JsonObject = {
        "namespace": settings.namespace,
        "aioNamespace": settings.aio_namespace,
        "image": settings.image,
        "simulatorImage": settings.simulator.image if settings.simulator else "",
        "simulatorHost": f"edge-assistant-camera.{settings.namespace}.svc.cluster.local",
        "cameraSecret": settings.camera_secret,
        "pullSecrets": (
            [{"name": settings.image_pull_secret}] if settings.image_pull_secret else []
        ),
        "mcpRoles": encode(settings.mcp_roles),
        "mcpAudience": settings.mcp.token_audience,
        "modelReaderRole": f"{AGENT}-{settings.namespace}-model",
        "foundryNamespace": settings.foundry.namespace,
        "foundryAudience": settings.foundry.token_audience,
        "modelName": settings.foundry.deployment_name,
        "modelSource": (
            {"assetId": settings.foundry.asset_id}
            if settings.foundry.asset_id
            else {
                "catalog": {
                    "name": settings.foundry.catalog_name,
                    "version": settings.foundry.catalog_version,
                }
            }
        ),
        "modelCompute": settings.foundry.compute,
        "modelNodeSelector": (
            {"kubernetes.azure.com/agentpool": settings.foundry.node_pool}
            if settings.foundry.node_pool
            else {}
        ),
        "modelTolerations": (
            [
                {
                    "key": "sku",
                    "operator": "Equal",
                    "value": settings.foundry.compute,
                    "effect": "NoSchedule",
                }
            ]
            if settings.foundry.node_pool
            else []
        ),
        "modelResources": (
            {
                "requests": {"cpu": "1", "memory": "4Gi"},
                "limits": {"cpu": "4", "memory": "8Gi", "gpu": 1},
            }
            if settings.foundry.compute == "gpu"
            else {
                "requests": {"cpu": "4", "memory": "4Gi"},
                "limits": {"cpu": "8", "memory": "8Gi"},
            }
        ),
        "settingsChecksum": hashlib.sha256(
            encode(settings.model_dump(by_alias=True)).encode()
        ).hexdigest(),
    }
    manifests = {}
    for group in (*GROUPS, *(("simulator",) if settings.simulator else ())):
        documents = []
        for document in yaml.safe_load_all((template_dir / f"{group}.yaml").read_text()):
            document = _substitute(document, variables)
            document["metadata"].setdefault("labels", {}).update(ownership(settings))
            documents.append(document)
        manifests[group] = documents
    manifests["workloads"].insert(
        0,
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": f"{AGENT}-settings",
                "namespace": settings.namespace,
                "labels": ownership(settings),
            },
            "data": {"config.json": encode(settings.model_dump(by_alias=True))},
        },
    )
    return manifests


def write_manifests(
    settings: Settings, manifests: dict[str, list[JsonObject]], destination: Path
) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for group, documents in manifests.items():
        (destination / f"{group}.yaml").write_text(
            yaml.safe_dump_all(documents, sort_keys=False), encoding="utf-8"
        )
    for obsolete in ("broker-rule.json", "certificates.yaml"):
        (destination / obsolete).unlink(missing_ok=True)
    subscriptions = [source.topic for source in settings.sources.values()]
    publications = []
    if settings.camera_graphs is not None:
        actions = (
            ("ContinuousMove", "Stop", "GetStatus") if settings.camera.enabled else ("GetStatus",)
        )
        subscriptions.extend(settings.camera.topic("responses", action) for action in actions)
        publications.extend(settings.camera.topic("requests", action) for action in actions)
    if settings.recommendations.enabled:
        publications.append(settings.recommendations.topic)
    access = {
        "endpoint": settings.mcp_url,
        "tokenAudience": settings.mcp.token_audience,
        "roles": settings.mcp_roles,
        "applicationTopics": {"subscribe": subscriptions, "publish": publications},
        "note": (
            "Review inventory, not an authorization policy. AIO's backend owns broker "
            "access; frontend roles and backend broker grants can be broader than these "
            "application-enforced topics. Never replace shared platform policies."
        ),
    }
    (destination / "mcp-access.json").write_text(
        json.dumps(access, indent=2) + "\n", encoding="utf-8"
    )
    if settings.camera_graphs is not None:
        from .camera_graphs import write_camera_graphs

        write_camera_graphs(settings, destination)


class Deployment:
    def __init__(self, settings: Settings, manifests: dict[str, list[JsonObject]]) -> None:
        self.settings = settings
        self.manifests = manifests

    def kubectl(
        self,
        *arguments: str,
        stdin: str | None = None,
        display: bool = False,
        timeout: int = 60,
    ) -> str:
        result = subprocess.run(
            [
                "kubectl",
                "--context",
                self.settings.kube_context,
                f"--request-timeout={timeout}s",
                *arguments,
            ],
            input=stdin,
            text=True,
            stdout=None if display else subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout + 30,
        )
        if result.returncode:
            raise SampleError(f"kubectl failed:\n{result.stderr.strip()}")
        return result.stdout or ""

    @staticmethod
    def target(document: JsonObject) -> list[str]:
        metadata = document["metadata"]
        resource = document["kind"].lower()
        version = document.get("apiVersion", "v1")
        if "/" in version:
            resource += "." + version.split("/")[0]
        arguments = [resource, metadata["name"]]
        if "namespace" in metadata:
            arguments += ["--namespace", metadata["namespace"]]
        return arguments

    def require_owned(self, documents: list[JsonObject], *, must_exist: bool = False) -> None:
        for document in documents:
            value = self.kubectl(
                "get", *self.target(document), "--ignore-not-found", "--output=json"
            )
            target = "/".join(self.target(document)[:2])
            if not value.strip():
                if must_exist:
                    raise SampleError(
                        f"{target} is missing; complete the preceding deployment step"
                    )
                continue
            existing = loads(value)
            labels = existing.get("metadata", {}).get("labels", {})
            if any(labels.get(key) != value for key, value in ownership(self.settings).items()):
                raise SampleError(
                    f"Refusing to modify {target}: it is not owned by this sample instance"
                )

    def apply(self, documents: list[JsonObject]) -> None:
        self.require_owned(documents)
        data = yaml.safe_dump_all(documents, sort_keys=False)
        self.kubectl("apply", "--dry-run=server", "-f", "-", stdin=data)
        self.kubectl("apply", "-f", "-", stdin=data, display=True)

    def trust(self) -> JsonObject:
        data = {}
        for destination, namespace, name, key in (
            (
                "aio-mcp.crt",
                self.settings.aio_namespace,
                self.settings.mcp.ca_config_map,
                self.settings.mcp.ca_key,
            ),
            (
                "foundry.crt",
                self.settings.foundry.namespace,
                self.settings.foundry.ca_config_map,
                self.settings.foundry.ca_key,
            ),
        ):
            payload = loads(
                self.kubectl("get", "configmap", name, "--namespace", namespace, "--output=json")
            )
            certificate = payload.get("data", {}).get(key)
            if not isinstance(certificate, str) or not certificate.strip():
                raise SampleError(f"ConfigMap {namespace}/{name} has no nonempty data[{key!r}]")
            try:
                ssl.create_default_context(cadata=certificate)
            except ssl.SSLError as error:
                raise SampleError(
                    f"ConfigMap {namespace}/{name} has an invalid CA bundle"
                ) from error
            data[destination] = certificate
        return {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": f"{AGENT}-trust",
                "namespace": self.settings.namespace,
                "labels": ownership(self.settings),
            },
            "data": data,
        }

    def prepare(self) -> None:
        self.kubectl(
            "get", "namespace", self.settings.aio_namespace, self.settings.foundry.namespace
        )
        self.kubectl(
            "get",
            "crd",
            "assets.namespaces.deviceregistry.microsoft.com",
            "devices.namespaces.deviceregistry.microsoft.com",
            "modeldeployments.foundrylocal.azure.com",
        )
        frontend = loads(
            self.kubectl(
                "get",
                "service",
                "aio-mcp-frontend",
                "--namespace",
                self.settings.aio_namespace,
                "--output=json",
            )
        )
        if not any(port.get("port") == 443 for port in frontend.get("spec", {}).get("ports", [])):
            raise SampleError("The built-in AIO MCP frontend must expose HTTPS on port 443")
        trust = self.trust()
        groups = [
            [item for item in self.manifests["namespace"] if item["kind"] == "Namespace"],
            [item for item in self.manifests["namespace"] if item["kind"] != "Namespace"],
            self.manifests["access"],
        ]
        self.require_owned([item for group in groups for item in group] + [trust])
        for group in groups:
            self.apply(group)
        self.apply([trust])

    def model(self) -> None:
        self.require_owned(self.manifests["namespace"], must_exist=True)
        self.apply(self.manifests["model"])
        print("ModelDeployment submitted. Initial model download can take several minutes.")

    def workloads(self) -> None:
        self.require_owned(self.manifests["namespace"] + self.manifests["model"], must_exist=True)
        if self.settings.image_pull_secret:
            secret_type = self.kubectl(
                "get",
                "secret",
                self.settings.image_pull_secret,
                "--namespace",
                self.settings.namespace,
                "--output=jsonpath={.type}",
            )
            if secret_type != "kubernetes.io/dockerconfigjson":
                raise SampleError("imagePullSecret must be an existing docker-registry pull secret")
        self.apply(self.manifests["workloads"])
        self.kubectl(
            "rollout",
            "status",
            f"deployment/{AGENT}",
            "--namespace",
            self.settings.namespace,
            "--timeout=600s",
            display=True,
            timeout=620,
        )

    def simulator_secrets(self) -> list[JsonObject]:
        return [
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {
                    "name": self.settings.camera_secret,
                    "namespace": namespace,
                    "labels": ownership(self.settings),
                },
                "type": "Opaque",
            }
            for namespace in (self.settings.namespace, self.settings.aio_namespace)
        ]

    def simulator(self) -> None:
        if self.settings.simulator is None:
            raise SampleError("Configure simulator.image before deploying the optional camera")
        self.require_owned(self.manifests["namespace"], must_exist=True)
        documents = self.simulator_secrets()
        self.require_owned(documents + self.manifests["simulator"])
        existing = []
        for document in documents:
            raw = self.kubectl("get", *self.target(document), "--ignore-not-found", "--output=json")
            data = loads(raw).get("data", {}) if raw.strip() else {}
            if raw.strip() and any(
                not isinstance(data.get(key), str) or not data[key]
                for key in ("username", "password")
            ):
                raise SampleError("Existing simulator credential Secret is missing required keys")
            existing.append(data)
        source = next((data for data in existing if data), None)
        credentials = (
            {key: source[key] for key in ("username", "password")}
            if source
            else {
                "username": base64.b64encode(b"camera").decode(),
                "password": base64.b64encode(secrets.token_urlsafe(32).encode()).decode(),
            }
        )
        if any(
            data and any(data[key] != value for key, value in credentials.items())
            for data in existing
        ):
            raise SampleError("Simulator credential Secrets disagree; refusing to rotate either")
        for index, document in enumerate(documents):
            document["data"] = dict(credentials)
            if index == 0:
                document["data"]["admin-token"] = (
                    existing[0].get("admin-token")
                    or base64.b64encode(secrets.token_urlsafe(32).encode()).decode()
                )
        self.apply(documents)
        self.apply(self.manifests["simulator"])
        self.kubectl(
            "rollout",
            "status",
            "deployment/edge-assistant-camera",
            "--namespace",
            self.settings.namespace,
            "--timeout=300s",
            display=True,
            timeout=320,
        )

    def status(self) -> None:
        self.kubectl(
            "get",
            "deployments,pods",
            "--namespace",
            self.settings.namespace,
            "--selector",
            f"app.kubernetes.io/part-of={PART_OF}",
            display=True,
        )
        self.kubectl(
            "get",
            "modeldeployment",
            self.settings.foundry.deployment_name,
            "--namespace",
            self.settings.foundry.namespace,
            "--output=yaml",
            display=True,
        )

    def client(self, command: str, *arguments: str, stdin: str | None = None) -> None:
        self.require_owned(
            [
                item
                for item in self.manifests["workloads"]
                if item["kind"] == "Deployment" and item["metadata"]["name"] == AGENT
            ],
            must_exist=True,
        )
        self.kubectl(
            "exec",
            "-i",
            f"deployment/{AGENT}",
            "--namespace",
            self.settings.namespace,
            "--container=agent",
            "--",
            "aio-edge-assistant",
            command,
            *arguments,
            stdin=stdin,
            display=True,
            timeout=360,
        )

    def cleanup(self) -> None:
        documents = [
            item
            for group in ("workloads", "model", "access", "namespace")
            for item in self.manifests[group]
            if item["kind"] != "Namespace"
        ]
        if self.settings.simulator is not None:
            documents = self.manifests["simulator"] + self.simulator_secrets() + documents
        documents.append(
            {
                "kind": "ConfigMap",
                "metadata": {"name": f"{AGENT}-trust", "namespace": self.settings.namespace},
            }
        )
        self.require_owned(documents)
        for document in documents:
            self.kubectl(
                "delete", *self.target(document), "--ignore-not-found", "--wait=false", display=True
            )
        print("Sample resources removed. Namespace, registry credentials, and platform retained.")

    def remove_legacy_mcp(self) -> None:
        current = loads(
            self.kubectl(
                "get", "deployment", AGENT, "--namespace", self.settings.namespace, "--output=json"
            )
        )
        containers = current["spec"]["template"]["spec"]["containers"]
        if [container["name"] for container in containers] != ["agent"]:
            raise SampleError("Deploy the frontend-only agent before removing legacy MCP resources")
        self.kubectl(
            "rollout",
            "status",
            f"deployment/{AGENT}",
            "--namespace",
            self.settings.namespace,
            "--timeout=180s",
            timeout=200,
        )
        self.client("check")
        targets = [
            ("apps/v1", "Deployment", "edge-resource-mcp", self.settings.namespace),
            ("v1", "Service", "edge-resource-mcp", self.settings.namespace),
            ("v1", "ServiceAccount", "edge-resource-mcp", self.settings.namespace),
            (
                "networking.k8s.io/v1",
                "NetworkPolicy",
                "edge-resource-mcp-ingress",
                self.settings.namespace,
            ),
        ]
        for kind, names in (
            ("Issuer", ("edge-resource-selfsigned", "edge-resource-ca")),
            ("Certificate", ("edge-resource-ca", "edge-resource-tls")),
            ("Secret", ("edge-resource-ca", "edge-resource-tls")),
        ):
            targets.extend(
                (
                    "v1" if kind == "Secret" else "cert-manager.io/v1",
                    kind,
                    name,
                    self.settings.namespace,
                )
                for name in names
            )
        for kind in ("Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"):
            cluster = kind.startswith("Cluster")
            name = (
                f"{PART_OF}-{self.settings.namespace}-token-reviewer"
                if cluster
                else f"edge-resource-mcp-{self.settings.namespace}"
            )
            targets.append(
                (
                    "rbac.authorization.k8s.io/v1",
                    kind,
                    name,
                    None if cluster else self.settings.aio_namespace,
                )
            )
        documents = [
            {
                "apiVersion": version,
                "kind": kind,
                "metadata": {"name": name, **({"namespace": namespace} if namespace else {})},
            }
            for version, kind, name, namespace in targets
        ]
        self.require_owned(documents)
        for document in documents:
            self.kubectl(
                "delete", *self.target(document), "--ignore-not-found", "--wait=false", display=True
            )
        print("Legacy custom MCP resources removed; built-in AIO services and model retained.")
