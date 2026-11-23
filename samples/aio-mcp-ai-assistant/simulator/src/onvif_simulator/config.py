from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml  # type: ignore[import-untyped]
from pydantic import BaseModel, Field, SecretStr, field_validator, model_validator
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
)


class StreamProfile(BaseModel):
    token: str
    path: str
    width: int = Field(ge=160, le=3840)
    height: int = Field(ge=120, le=2160)
    frame_rate: int = Field(ge=1, le=60)
    bitrate_kbps: int = Field(ge=64, le=20_000)
    key_frame_interval: int = Field(ge=1, le=600)

    @field_validator("token", "path")
    @classmethod
    def validate_identifier(cls, value: str) -> str:
        if not value or not value.replace("_", "").replace("-", "").isalnum():
            raise ValueError("must contain only letters, numbers, hyphens, or underscores")
        return value


def default_profiles() -> dict[str, StreamProfile]:
    return {
        "high": StreamProfile(
            token="profile_high",
            path="stream1",
            width=1920,
            height=1080,
            frame_rate=15,
            bitrate_kbps=1024,
            key_frame_interval=15,
        ),
        "standard": StreamProfile(
            token="profile_standard",
            path="stream2",
            width=640,
            height=360,
            frame_rate=10,
            bitrate_kbps=512,
            key_frame_interval=20,
        ),
    }


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ONVIF_SIMULATOR_",
        env_nested_delimiter="__",
        case_sensitive=False,
        extra="forbid",
    )

    bind_host: str = "0.0.0.0"
    http_port: int = Field(default=2020, ge=1, le=65535)
    rtsp_port: int = Field(default=8554, ge=1, le=65535)
    advertised_host: str = "onvif-simulator.default.svc.cluster.local"
    advertised_http_port: int = Field(default=2020, ge=1, le=65535)
    advertised_rtsp_port: int = Field(default=554, ge=1, le=65535)
    image_dir: Path = Path("/app/img")
    initial_image: str = "scene.png"
    camera_username: str = Field(min_length=1, max_length=128)
    camera_password: SecretStr = Field(min_length=16, max_length=256)
    admin_token: SecretStr | None = None
    admin_required: bool = True
    state_path: Path = Path("/app/state/camera-state.json")
    discovery_enabled: bool = False
    diagnostic_overlay: bool = False
    log_level: str = "INFO"
    manufacturer: str = "Azure IoT Operations Samples"
    model: str = "ONVIF Static Image Simulator"
    firmware_version: str = "0.1.0"
    serial_number: str = "AIO-ONVIF-SIM-001"
    hardware_id: str = "ONVIF-SIM-PYTHON"
    profiles: dict[str, StreamProfile] = Field(default_factory=default_profiles)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return env_settings, init_settings, dotenv_settings, file_secret_settings

    @field_validator("initial_image")
    @classmethod
    def validate_initial_image(cls, value: str) -> str:
        if not value or Path(value).name != value or "/" in value or "\\" in value:
            raise ValueError("initial_image must be a file name directly inside image_dir")
        return value

    @field_validator("log_level")
    @classmethod
    def normalize_log_level(cls, value: str) -> str:
        normalized = value.upper()
        if normalized not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise ValueError("log_level must be DEBUG, INFO, WARNING, ERROR, or CRITICAL")
        return normalized

    @model_validator(mode="after")
    def validate_settings(self) -> Settings:
        if self.admin_required and (
            self.admin_token is None or not self.admin_token.get_secret_value()
        ):
            raise ValueError("ONVIF_SIMULATOR_ADMIN_TOKEN is required when admin_required is true")
        if not self.profiles:
            raise ValueError("at least one media profile is required")
        tokens = [profile.token for profile in self.profiles.values()]
        paths = [profile.path for profile in self.profiles.values()]
        if len(tokens) != len(set(tokens)):
            raise ValueError("media profile tokens must be unique")
        if len(paths) != len(set(paths)):
            raise ValueError("media profile paths must be unique")
        return self

    @property
    def http_base_url(self) -> str:
        return f"http://{self.advertised_host}:{self.advertised_http_port}"

    @property
    def rtsp_base_url(self) -> str:
        return f"rtsp://{self.advertised_host}:{self.advertised_rtsp_port}"

    def profile_by_token(self, token: str) -> StreamProfile:
        for profile in self.profiles.values():
            if profile.token == token:
                return profile
        raise KeyError(token)

    def profile_by_path(self, path: str) -> StreamProfile:
        normalized = path.strip("/").split("/", 1)[0]
        for profile in self.profiles.values():
            if profile.path == normalized:
                return profile
        raise KeyError(path)


def load_settings(config_path: Path | None) -> Settings:
    values: dict[str, Any] = {}
    if config_path is not None:
        try:
            raw = config_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ValueError(f"unable to read configuration file {config_path}: {exc}") from exc
        parsed = yaml.safe_load(raw)
        if parsed is not None and not isinstance(parsed, dict):
            raise ValueError(f"configuration file {config_path} must contain a YAML object")
        values = parsed or {}
    return Settings(**values)
