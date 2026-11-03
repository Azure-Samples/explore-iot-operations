import re
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .common import loads

NAME = r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"
KEY = r"^[A-Za-z0-9._-]+$"
TOPIC = r"^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)*$"
CATALOG_ASSET_ID = (
    r"^azureml://registries/[A-Za-z0-9][A-Za-z0-9_-]*/models/"
    r"[A-Za-z0-9][A-Za-z0-9._-]*/versions/[A-Za-z0-9][A-Za-z0-9._-]*$"
)
PART_OF = "aio-mcp-ai-assistant"
AGENT = "edge-assistant"
RESOURCES = "edge-resource-mcp"
RESOURCE_AUDIENCE = "edge-resource-mcp"
SETTINGS_PATH = Path("/etc/edge-assistant/config.json")
KUBE_TOKEN = Path("/var/run/kubernetes/token")
KUBE_CA = Path("/var/run/kubernetes/ca.crt")
FOUNDRY_TOKEN = Path("/var/run/foundry/token")
FOUNDRY_CA = Path("/var/run/trust/foundry.crt")
BROKER_TOKEN = Path("/var/run/broker/token")
BROKER_CA = Path("/var/run/trust/broker.crt")
RESOURCE_TOKEN = Path("/var/run/resource-mcp/token")
RESOURCE_CA = Path("/var/run/resource-ca/ca.crt")


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True, strict=True)


class Broker(StrictModel):
    host: str = Field(min_length=1, max_length=253, pattern=r"^[a-z0-9][a-z0-9.-]*$")
    port: int = Field(ge=1, le=65535)
    ca_config_map: str = Field(alias="caConfigMap", max_length=63, pattern=NAME)
    ca_key: str = Field(alias="caKey", min_length=1, max_length=253, pattern=KEY)


class Foundry(StrictModel):
    namespace: str = Field(max_length=63, pattern=NAME)
    deployment_name: str = Field(alias="deploymentName", max_length=63, pattern=NAME)
    catalog_name: str = Field(alias="catalogName", min_length=1, max_length=128, pattern=KEY)
    catalog_version: str = Field(alias="catalogVersion", min_length=1, max_length=32, pattern=KEY)
    asset_id: str | None = Field(
        default=None, alias="assetId", max_length=256, pattern=CATALOG_ASSET_ID
    )
    compute: Literal["cpu", "gpu"] = "cpu"
    node_pool: str | None = Field(default=None, alias="nodePool", max_length=63, pattern=NAME)
    token_audience: str = Field(
        alias="tokenAudience", min_length=1, max_length=128, pattern=r"^[A-Za-z0-9:/._-]+$"
    )
    ca_config_map: str = Field(alias="caConfigMap", max_length=63, pattern=NAME)
    ca_key: str = Field(alias="caKey", min_length=1, max_length=253, pattern=KEY)

    @model_validator(mode="after")
    def validate_model(self) -> "Foundry":
        if self.asset_id is not None:
            if self.catalog_version.lower() == "latest":
                raise ValueError("assetId requires a concrete catalogVersion, not latest")
            if not self.asset_id.endswith(
                f"/models/{self.catalog_name}/versions/{self.catalog_version}"
            ):
                raise ValueError("assetId must match catalogName and catalogVersion")
        if self.compute == "gpu" and self.node_pool is None:
            raise ValueError("GPU deployments require foundry.nodePool for explicit placement")
        return self


class Source(StrictModel):
    stage: str = Field(min_length=1, max_length=63, pattern=r"^[a-z0-9][a-z0-9-]*$")
    machine_id: str | None = Field(
        default=None,
        alias="machineId",
        min_length=1,
        max_length=63,
        pattern=r"^[a-z0-9][a-z0-9-]*$",
    )
    topic: str = Field(min_length=1, max_length=200, pattern=TOPIC)
    description: str = Field(min_length=1, max_length=300)


class Camera(StrictModel):
    enabled: bool = False
    asset_name: str = Field(
        default="edge-assistant-camera-onvif", alias="assetName", max_length=63, pattern=NAME
    )
    profile_token: str = Field(
        default="profile_high", alias="profileToken", min_length=1, max_length=128, pattern=KEY
    )

    def action_topic(self, action: str) -> str:
        if action not in {"ContinuousMove", "Stop", "GetStatus"}:
            raise ValueError("Unsupported camera action")
        return f"azure-iot-operations/asset-operations/{self.asset_name}/PTZ/{action}"


class Recommendations(StrictModel):
    enabled: bool = False
    topic: str = Field(
        default="edge/assistant/recommendations", min_length=1, max_length=200, pattern=TOPIC
    )


def validate_image(value: str) -> str:
    if not re.fullmatch(
        r"[a-z0-9][a-z0-9.:-]*/[a-z0-9][a-z0-9/_.-]*"
        r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})",
        value,
    ) or value.endswith(":latest"):
        raise ValueError("image must include a registry and an explicit version tag or digest")
    return value


class Simulator(StrictModel):
    image: str = Field(min_length=1, max_length=300, pattern=r"^\S+$")

    @model_validator(mode="after")
    def validate_scope(self) -> "Simulator":
        validate_image(self.image)
        return self


class Settings(StrictModel):
    kube_context: str = Field(alias="kubeContext", min_length=1, max_length=253, pattern=r"^\S+$")
    namespace: str = Field(max_length=40, pattern=NAME)
    aio_namespace: str = Field(alias="aioNamespace", max_length=63, pattern=NAME)
    image: str = Field(min_length=1, max_length=300, pattern=r"^\S+$")
    image_pull_secret: str = Field(alias="imagePullSecret", max_length=63, pattern=r"^[a-z0-9-]*$")
    broker: Broker
    foundry: Foundry
    sources: dict[str, Source] = Field(min_length=1, max_length=8)
    camera: Camera = Field(default_factory=Camera)
    recommendations: Recommendations = Field(default_factory=Recommendations)
    simulator: Simulator | None = None

    @model_validator(mode="after")
    def validate_scope(self) -> "Settings":
        if "REPLACE_WITH_" in self.model_dump_json():
            raise ValueError("Replace every REPLACE_WITH_ configuration value")
        if self.namespace in {
            "default",
            "kube-system",
            "kube-public",
            "kube-node-lease",
            self.aio_namespace,
            self.foundry.namespace,
        }:
            raise ValueError("Use a dedicated sample namespace, not an existing platform namespace")
        if any(not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", name) for name in self.sources):
            raise ValueError("Source names must be 1-40 lowercase letters, digits, or hyphens")
        if len({source.topic for source in self.sources.values()}) != len(self.sources):
            raise ValueError("Each source must use a distinct, exact MQTT topic")
        if len({(source.stage, source.machine_id) for source in self.sources.values()}) != len(
            self.sources
        ):
            raise ValueError("Each source must have a distinct stage/machineId binding")
        reserved_topics = {
            self.camera.action_topic(action) for action in ("ContinuousMove", "Stop", "GetStatus")
        } | {self.camera_response_topic}
        if self.recommendations.topic in reserved_topics:
            raise ValueError(
                "recommendations.topic must not overlap camera command or reply topics"
            )
        if self.recommendations.topic in {source.topic for source in self.sources.values()}:
            raise ValueError("recommendations.topic must not overwrite an observation source")
        validate_image(self.image)
        if self.image_pull_secret and not re.fullmatch(NAME, self.image_pull_secret):
            raise ValueError("imagePullSecret must be a Kubernetes name or an empty string")
        return self

    @property
    def resource_url(self) -> str:
        return f"https://{RESOURCES}.{self.namespace}.svc.cluster.local/mcp"

    @property
    def model_id(self) -> str:
        return f"{self.foundry.catalog_name}:{self.foundry.catalog_version}"

    @property
    def cluster_role(self) -> str:
        return f"{PART_OF}-{self.namespace}-token-reviewer"

    @property
    def camera_response_topic(self) -> str:
        return f"clients/{AGENT}-{self.namespace}/camera/response"

    @property
    def camera_secret(self) -> str:
        return f"edge-camera-{self.namespace}"


def load_settings(path: Path = SETTINGS_PATH) -> Settings:
    return Settings.model_validate(loads(path.read_bytes()))
