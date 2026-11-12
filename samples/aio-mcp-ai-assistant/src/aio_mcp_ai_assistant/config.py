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
SETTINGS_PATH = Path("/etc/edge-assistant/config.json")
KUBE_TOKEN = Path("/var/run/kubernetes/token")
KUBE_CA = Path("/var/run/kubernetes/ca.crt")
FOUNDRY_TOKEN = Path("/var/run/foundry/token")
FOUNDRY_CA = Path("/var/run/trust/foundry.crt")
MCP_TOKEN = Path("/var/run/aio-mcp/token")
MCP_CA = Path("/var/run/trust/aio-mcp.crt")


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True, strict=True)


class Mcp(StrictModel):
    token_audience: str = Field(
        default="aio-mcp-frontend",
        alias="tokenAudience",
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9:/._-]+$",
    )
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
    topic_prefix: str = Field(
        default="edge/assistant/camera", alias="topicPrefix", max_length=160, pattern=TOPIC
    )

    def topic(self, direction: Literal["requests", "responses"], action: str) -> str:
        if action not in {"ContinuousMove", "Stop", "GetStatus"}:
            raise ValueError("Unsupported camera action")
        return f"{self.topic_prefix}/{direction}/{action}"


class CameraGraphs(StrictModel):
    registry: str = Field(min_length=1, max_length=253, pattern=r"^[a-z0-9][a-z0-9.-]*$")
    registry_endpoint_name: str = Field(alias="registryEndpointName", max_length=63, pattern=NAME)
    artifact_version: str = Field(
        alias="artifactVersion",
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$",
    )

    @model_validator(mode="after")
    def validate_version(self) -> "CameraGraphs":
        if self.artifact_version == "latest":
            raise ValueError("cameraGraphs.artifactVersion must be an explicit version, not latest")
        return self


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
    mcp: Mcp
    foundry: Foundry
    sources: dict[str, Source] = Field(min_length=1, max_length=8)
    camera: Camera = Field(default_factory=Camera)
    camera_graphs: CameraGraphs | None = Field(default=None, alias="cameraGraphs")
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
            self.camera.topic(direction, action)
            for direction in ("requests", "responses")
            for action in ("ContinuousMove", "Stop", "GetStatus")
        }
        if self.recommendations.topic in reserved_topics:
            raise ValueError(
                "recommendations.topic must not overlap camera command or reply topics"
            )
        if self.recommendations.topic in {source.topic for source in self.sources.values()}:
            raise ValueError("recommendations.topic must not overwrite an observation source")
        if reserved_topics & {source.topic for source in self.sources.values()}:
            raise ValueError("Observation sources must not overlap camera bridge topics")
        if self.camera.enabled and self.camera_graphs is None:
            raise ValueError(
                "camera.enabled requires cameraGraphs; deploy the camera-control data flow graphs first"
            )
        validate_image(self.image)
        if self.image_pull_secret and not re.fullmatch(NAME, self.image_pull_secret):
            raise ValueError("imagePullSecret must be a Kubernetes name or an empty string")
        return self

    @property
    def mcp_url(self) -> str:
        return f"https://aio-mcp-frontend.{self.aio_namespace}.svc.cluster.local/mcp"

    @property
    def mcp_roles(self) -> list[str]:
        roles = ["Reader", "DataReader"]
        if self.camera_graphs is not None or self.recommendations.enabled:
            roles.append("Admin")
        return roles

    @property
    def model_id(self) -> str:
        return f"{self.foundry.catalog_name}:{self.foundry.catalog_version}"

    @property
    def camera_profile_name(self) -> str:
        return f"edge-camera-{self.namespace}"

    @property
    def camera_secret(self) -> str:
        return f"edge-camera-{self.namespace}"


def load_settings(path: Path = SETTINGS_PATH) -> Settings:
    return Settings.model_validate(loads(path.read_bytes()))
