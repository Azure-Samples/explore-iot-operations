from __future__ import annotations

import hashlib
from collections.abc import Callable
from pathlib import Path

import pytest
from PIL import Image
from pydantic import SecretStr

from onvif_simulator.authentication import REALM
from onvif_simulator.config import Settings, StreamProfile


@pytest.fixture
def image_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "img"
    directory.mkdir()
    Image.new("RGB", (640, 480), "red").save(directory / "camera.jpg")
    Image.new("RGB", (640, 480), "blue").save(directory / "warehouse.png")
    (directory / "corrupt.jpg").write_text("not an image", encoding="utf-8")
    (directory / "notes.txt").write_text("not an image", encoding="utf-8")
    return directory


@pytest.fixture
def settings(image_dir: Path, tmp_path: Path) -> Settings:
    return Settings(
        bind_host="127.0.0.1",
        http_port=12020,
        rtsp_port=18554,
        advertised_host="127.0.0.1",
        advertised_http_port=12020,
        advertised_rtsp_port=18554,
        image_dir=image_dir,
        initial_image="camera.jpg",
        camera_username="test-camera",
        camera_password=SecretStr("test-camera-password"),
        admin_token=SecretStr("test-admin-token"),
        state_path=tmp_path / "state" / "camera-state.json",
        profiles={
            "high": StreamProfile(
                token="profile_high",
                path="stream1",
                width=320,
                height=240,
                frame_rate=5,
                bitrate_kbps=256,
                key_frame_interval=5,
            ),
            "standard": StreamProfile(
                token="profile_standard",
                path="stream2",
                width=160,
                height=120,
                frame_rate=5,
                bitrate_kbps=128,
                key_frame_interval=5,
            ),
        },
    )


@pytest.fixture
def digest_header(settings: Settings) -> Callable[..., str]:
    def create(
        nonce: str,
        *,
        method: str = "POST",
        uri: str = "/onvif/ptz_service",
        nc: str = "00000001",
        cnonce: str = "test-client",
        qop: str | None = "auth",
    ) -> str:
        def md5(value: str) -> str:
            return hashlib.md5(value.encode()).hexdigest()  # noqa: S324 - Digest protocol.

        ha1 = md5(
            f"{settings.camera_username}:{REALM}:{settings.camera_password.get_secret_value()}"
        )
        ha2 = md5(f"{method}:{uri}")
        response = md5(
            f"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}" if qop else f"{ha1}:{nonce}:{ha2}"
        )
        header = (
            f'Digest username="{settings.camera_username}", realm="{REALM}", '
            f'nonce="{nonce}", uri="{uri}", response="{response}", algorithm=MD5'
        )
        if qop is not None:
            header += f', qop="{qop}", nc={nc}, cnonce="{cnonce}"'
        return header

    return create
