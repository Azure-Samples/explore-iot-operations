from __future__ import annotations

import json
import math
import os
import threading
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


@dataclass
class PTZPosition:
    pan: float = 0.0
    tilt: float = 0.0
    zoom: float = 0.0

    def normalized(self) -> PTZPosition:
        return PTZPosition(
            pan=clamp(self.pan, -1.0, 1.0),
            tilt=clamp(self.tilt, -1.0, 1.0),
            zoom=clamp(self.zoom, 0.0, 1.0),
        )


@dataclass
class PTZVelocity:
    pan: float = 0.0
    tilt: float = 0.0
    zoom: float = 0.0

    @property
    def moving(self) -> bool:
        return any(not math.isclose(value, 0.0) for value in asdict(self).values())


@dataclass
class ImagingSettings:
    brightness: float = 50.0
    contrast: float = 50.0
    color_saturation: float = 50.0
    sharpness: float = 50.0

    def normalized(self) -> ImagingSettings:
        return ImagingSettings(
            brightness=clamp(self.brightness, 0.0, 100.0),
            contrast=clamp(self.contrast, 0.0, 100.0),
            color_saturation=clamp(self.color_saturation, 0.0, 100.0),
            sharpness=clamp(self.sharpness, 0.0, 100.0),
        )


@dataclass
class Preset:
    token: str
    name: str
    position: PTZPosition


@dataclass(frozen=True)
class CameraSnapshot:
    position: PTZPosition
    velocity: PTZVelocity
    imaging: ImagingSettings
    home: PTZPosition
    presets: tuple[Preset, ...]
    last_update: datetime


@dataclass
class CameraState:
    state_path: Path
    position: PTZPosition = field(default_factory=PTZPosition)
    velocity: PTZVelocity = field(default_factory=PTZVelocity)
    imaging: ImagingSettings = field(default_factory=ImagingSettings)
    home: PTZPosition = field(default_factory=PTZPosition)
    presets: dict[str, Preset] = field(default_factory=dict)
    last_update: datetime = field(default_factory=lambda: datetime.now(UTC))
    relay_active: bool = False
    _lock: threading.RLock = field(default_factory=threading.RLock, init=False, repr=False)
    _next_preset: int = field(default=1, init=False, repr=False)
    _continuous_move_remaining_seconds: float | None = field(
        default=None,
        init=False,
        repr=False,
    )

    def load(self) -> None:
        if not self.state_path.exists():
            return
        try:
            payload = json.loads(self.state_path.read_text(encoding="utf-8"))
            position = PTZPosition(**payload.get("position", {})).normalized()
            imaging = ImagingSettings(**payload.get("imaging", {})).normalized()
            home = PTZPosition(**payload.get("home", {})).normalized()
            presets = {
                str(item["token"]): Preset(
                    token=str(item["token"]),
                    name=str(item["name"]),
                    position=PTZPosition(**item["position"]).normalized(),
                )
                for item in payload.get("presets", [])
            }
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
            raise ValueError(f"unable to load camera state from {self.state_path}: {exc}") from exc
        with self._lock:
            self.position = position
            self.imaging = imaging
            self.home = home
            self.presets = presets
            self._next_preset = self._calculate_next_preset()

    def snapshot(self) -> CameraSnapshot:
        with self._lock:
            return CameraSnapshot(
                position=PTZPosition(**asdict(self.position)),
                velocity=PTZVelocity(**asdict(self.velocity)),
                imaging=ImagingSettings(**asdict(self.imaging)),
                home=PTZPosition(**asdict(self.home)),
                presets=tuple(
                    Preset(item.token, item.name, PTZPosition(**asdict(item.position)))
                    for item in self.presets.values()
                ),
                last_update=self.last_update,
            )

    def update_motion(self, elapsed_seconds: float) -> None:
        with self._lock:
            if not self.velocity.moving:
                return
            motion_seconds = elapsed_seconds
            if self._continuous_move_remaining_seconds is not None:
                motion_seconds = min(
                    motion_seconds,
                    self._continuous_move_remaining_seconds,
                )
            self.position = PTZPosition(
                pan=self.position.pan + self.velocity.pan * motion_seconds,
                tilt=self.position.tilt + self.velocity.tilt * motion_seconds,
                zoom=self.position.zoom + self.velocity.zoom * motion_seconds,
            ).normalized()
            self.last_update = datetime.now(UTC)
            if self._continuous_move_remaining_seconds is not None:
                self._continuous_move_remaining_seconds -= elapsed_seconds
                if self._continuous_move_remaining_seconds <= 0:
                    self.velocity = PTZVelocity()
                    self._continuous_move_remaining_seconds = None
                    self.persist()

    def absolute_move(self, position: PTZPosition) -> None:
        with self._lock:
            self.position = position.normalized()
            self.velocity = PTZVelocity()
            self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)
            self.persist()

    def relative_move(self, translation: PTZPosition) -> None:
        with self._lock:
            self.position = PTZPosition(
                pan=self.position.pan + translation.pan,
                tilt=self.position.tilt + translation.tilt,
                zoom=self.position.zoom + translation.zoom,
            ).normalized()
            self.velocity = PTZVelocity()
            self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)
            self.persist()

    def continuous_move(
        self,
        velocity: PTZVelocity,
        timeout_seconds: float | None = None,
    ) -> None:
        with self._lock:
            self.velocity = PTZVelocity(
                pan=clamp(velocity.pan, -1.0, 1.0),
                tilt=clamp(velocity.tilt, -1.0, 1.0),
                zoom=clamp(velocity.zoom, -1.0, 1.0),
            )
            self._continuous_move_remaining_seconds = timeout_seconds
            if timeout_seconds is not None and timeout_seconds <= 0:
                self.velocity = PTZVelocity()
                self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)

    def stop(self, pan_tilt: bool = True, zoom: bool = True) -> None:
        with self._lock:
            self.velocity = PTZVelocity(
                pan=0.0 if pan_tilt else self.velocity.pan,
                tilt=0.0 if pan_tilt else self.velocity.tilt,
                zoom=0.0 if zoom else self.velocity.zoom,
            )
            self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)
            self.persist()

    def set_home(self) -> None:
        with self._lock:
            self.home = PTZPosition(**asdict(self.position))
            self.persist()

    def goto_home(self) -> None:
        with self._lock:
            self.position = PTZPosition(**asdict(self.home))
            self.velocity = PTZVelocity()
            self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)
            self.persist()

    def set_preset(self, name: str | None, token: str | None) -> Preset:
        with self._lock:
            preset_token = token or f"preset_{self._next_preset}"
            if token is None:
                self._next_preset += 1
            preset = Preset(
                token=preset_token,
                name=name or preset_token,
                position=PTZPosition(**asdict(self.position)),
            )
            self.presets[preset_token] = preset
            self.persist()
            return preset

    def remove_preset(self, token: str) -> None:
        with self._lock:
            if token not in self.presets:
                raise KeyError(token)
            del self.presets[token]
            self.persist()

    def goto_preset(self, token: str) -> None:
        with self._lock:
            preset = self.presets.get(token)
            if preset is None:
                raise KeyError(token)
            self.position = PTZPosition(**asdict(preset.position))
            self.velocity = PTZVelocity()
            self._continuous_move_remaining_seconds = None
            self.last_update = datetime.now(UTC)
            self.persist()

    def set_imaging(self, **values: float) -> None:
        with self._lock:
            current = asdict(self.imaging)
            current.update(values)
            self.imaging = ImagingSettings(**current).normalized()
            self.persist()

    def set_relay(self, active: bool) -> None:
        with self._lock:
            self.relay_active = active

    def persist(self) -> None:
        payload: dict[str, Any] = {
            "position": asdict(self.position),
            "imaging": asdict(self.imaging),
            "home": asdict(self.home),
            "presets": [
                {
                    "token": preset.token,
                    "name": preset.name,
                    "position": asdict(preset.position),
                }
                for preset in self.presets.values()
            ],
        }
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.state_path.with_suffix(f"{self.state_path.suffix}.tmp")
            temporary.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            os.replace(temporary, self.state_path)
        except OSError as exc:
            raise RuntimeError(
                f"unable to persist camera state to {self.state_path}: {exc}"
            ) from exc

    def _calculate_next_preset(self) -> int:
        indexes = [
            int(token.removeprefix("preset_"))
            for token in self.presets
            if token.startswith("preset_") and token.removeprefix("preset_").isdigit()
        ]
        return max(indexes, default=0) + 1
