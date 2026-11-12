from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from threading import RLock

from PIL import Image, ImageDraw, ImageEnhance

from onvif_simulator.config import StreamProfile
from onvif_simulator.image_catalog import ImageCatalog
from onvif_simulator.state import CameraSnapshot, CameraState


@dataclass(frozen=True)
class ViewportStatus:
    image_name: str
    source_width: int
    source_height: int
    left: int
    top: int
    width: int
    height: int
    pan: float
    tilt: float
    zoom: float
    indicator: str


def format_pan_indicator(
    pan: float,
    viewport_fraction: float,
    track_width: int = 16,
) -> str:
    viewport_width = max(2, min(track_width, round(viewport_fraction * track_width)))
    travel = track_width - viewport_width
    left = round(travel * (max(-1.0, min(1.0, pan)) + 1.0) / 2.0)
    marker = f"[{'-' * (viewport_width - 2)}]"
    return f"[{'-' * left}{marker}{'-' * (travel - left)}]"


class FrameRenderer:
    def __init__(
        self,
        catalog: ImageCatalog,
        state: CameraState,
        diagnostic_overlay: bool = False,
    ) -> None:
        self._catalog = catalog
        self._state = state
        self._diagnostic_overlay = diagnostic_overlay
        self._cache: dict[str, tuple[tuple[object, ...], Image.Image]] = {}
        self._cache_lock = RLock()

    @property
    def image_revision(self) -> int:
        return self._catalog.revision

    def viewport_status(self, profile: StreamProfile) -> ViewportStatus:
        image_snapshot = self._catalog.snapshot()
        camera = self._state.snapshot()
        box = self._viewport_box(
            image_snapshot.image.size,
            camera,
            profile.width / profile.height,
        )
        left, top, right, bottom = box
        width = right - left
        height = bottom - top
        return ViewportStatus(
            image_name=image_snapshot.name,
            source_width=image_snapshot.image.width,
            source_height=image_snapshot.image.height,
            left=left,
            top=top,
            width=width,
            height=height,
            pan=camera.position.pan,
            tilt=camera.position.tilt,
            zoom=camera.position.zoom,
            indicator=format_pan_indicator(
                camera.position.pan,
                width / image_snapshot.image.width,
            ),
        )

    def render(self, profile: StreamProfile) -> Image.Image:
        image_snapshot = self._catalog.snapshot()
        camera = self._state.snapshot()
        cache_key = (
            image_snapshot.revision,
            camera.position.pan,
            camera.position.tilt,
            camera.position.zoom,
            camera.imaging.brightness,
            camera.imaging.contrast,
            camera.imaging.color_saturation,
            camera.imaging.sharpness,
            profile.width,
            profile.height,
            self._diagnostic_overlay,
        )
        if not self._diagnostic_overlay:
            with self._cache_lock:
                cached = self._cache.get(profile.token)
                if cached is not None and cached[0] == cache_key:
                    return cached[1]

        rendered = self._crop_for_ptz(
            image_snapshot.image,
            camera,
            profile.width / profile.height,
        )
        rendered = rendered.resize((profile.width, profile.height), Image.Resampling.LANCZOS)
        rendered = self._apply_imaging(rendered, camera)
        if self._diagnostic_overlay:
            self._add_overlay(rendered, image_snapshot.name, camera)
        else:
            with self._cache_lock:
                self._cache[profile.token] = (cache_key, rendered)
        return rendered

    @classmethod
    def _crop_for_ptz(
        cls,
        image: Image.Image,
        camera: CameraSnapshot,
        target_aspect: float,
    ) -> Image.Image:
        return image.crop(cls._viewport_box(image.size, camera, target_aspect))

    @staticmethod
    def _viewport_box(
        image_size: tuple[int, int],
        camera: CameraSnapshot,
        target_aspect: float,
    ) -> tuple[int, int, int, int]:
        width, height = image_size
        source_aspect = width / height
        if source_aspect > target_aspect:
            base_height = height
            base_width = int(height * target_aspect)
        else:
            base_width = width
            base_height = int(width / target_aspect)

        zoom_factor = 1.0 + camera.position.zoom * 3.0
        crop_width = max(1, int(base_width / zoom_factor))
        crop_height = max(1, int(base_height / zoom_factor))
        horizontal_travel = max(0, width - crop_width)
        vertical_travel = max(0, height - crop_height)
        left = int(horizontal_travel * (camera.position.pan + 1.0) / 2.0)
        top = int(vertical_travel * (1.0 - camera.position.tilt) / 2.0)
        left = max(0, min(left, width - crop_width))
        top = max(0, min(top, height - crop_height))
        return (left, top, left + crop_width, top + crop_height)

    @staticmethod
    def _apply_imaging(image: Image.Image, camera: CameraSnapshot) -> Image.Image:
        imaging = camera.imaging
        image = ImageEnhance.Brightness(image).enhance(max(0.0, imaging.brightness / 50.0))
        image = ImageEnhance.Contrast(image).enhance(max(0.0, imaging.contrast / 50.0))
        image = ImageEnhance.Color(image).enhance(max(0.0, imaging.color_saturation / 50.0))
        return ImageEnhance.Sharpness(image).enhance(max(0.0, imaging.sharpness / 50.0))

    @staticmethod
    def _add_overlay(image: Image.Image, name: str, camera: CameraSnapshot) -> None:
        draw = ImageDraw.Draw(image)
        text = (
            f"{name} | {datetime.now(UTC).isoformat(timespec='seconds')} | "
            f"PTZ {camera.position.pan:.2f},{camera.position.tilt:.2f},"
            f"{camera.position.zoom:.2f}"
        )
        draw.rectangle((8, 8, min(image.width - 8, 16 + len(text) * 7), 31), fill="black")
        draw.text((12, 12), text, fill="white")
