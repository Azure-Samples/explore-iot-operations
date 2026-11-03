from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from onvif_simulator.config import StreamProfile
from onvif_simulator.image_catalog import ImageCatalog
from onvif_simulator.renderer import FrameRenderer, format_pan_indicator
from onvif_simulator.state import CameraState, PTZPosition, PTZVelocity


def test_ptz_operations_and_persistence(image_dir: Path, tmp_path: Path) -> None:
    state_path = tmp_path / "state.json"
    state = CameraState(state_path)
    state.absolute_move(PTZPosition(0.5, -0.25, 0.75))
    preset = state.set_preset("inspection", None)
    state.continuous_move(PTZVelocity(-0.5, 0.25, -0.5))
    state.update_motion(0.5)
    state.stop()

    assert state.snapshot().position == PTZPosition(0.25, -0.125, 0.5)
    assert preset.token == "preset_1"

    restored = CameraState(state_path)
    restored.load()
    assert restored.snapshot().position == state.snapshot().position
    assert restored.snapshot().presets[0].name == "inspection"


def test_renderer_applies_profile_dimensions(image_dir: Path, tmp_path: Path) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")
    state = CameraState(tmp_path / "state.json")
    state.absolute_move(PTZPosition(1.0, 1.0, 1.0))
    renderer = FrameRenderer(catalog, state)
    profile = StreamProfile(
        token="test",
        path="test",
        width=320,
        height=180,
        frame_rate=5,
        bitrate_kbps=128,
        key_frame_interval=5,
    )

    frame = renderer.render(profile)

    assert frame.size == (320, 180)


def test_pan_moves_camera_viewport_across_panorama(tmp_path: Path) -> None:
    image_dir = tmp_path / "img"
    image_dir.mkdir()
    panorama = Image.new("RGB", (900, 180))
    draw = ImageDraw.Draw(panorama)
    draw.rectangle((0, 0, 299, 179), fill="red")
    draw.rectangle((300, 0, 599, 179), fill="green")
    draw.rectangle((600, 0, 899, 179), fill="blue")
    panorama.save(image_dir / "panorama.png")

    catalog = ImageCatalog(image_dir, "panorama.png")
    state = CameraState(tmp_path / "state.json")
    renderer = FrameRenderer(catalog, state)
    profile = StreamProfile(
        token="panorama",
        path="panorama",
        width=320,
        height=180,
        frame_rate=5,
        bitrate_kbps=128,
        key_frame_interval=5,
    )

    state.absolute_move(PTZPosition(-1.0, 0.0, 0.0))
    left = renderer.render(profile).getpixel((160, 90))
    state.absolute_move(PTZPosition(0.0, 0.0, 0.0))
    center = renderer.render(profile).getpixel((160, 90))
    state.absolute_move(PTZPosition(1.0, 0.0, 0.0))
    right = renderer.render(profile).getpixel((160, 90))

    assert left == (255, 0, 0)
    assert center == (0, 128, 0)
    assert right == (0, 0, 255)


def test_renderer_reuses_frame_until_view_changes(image_dir: Path, tmp_path: Path) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")
    state = CameraState(tmp_path / "state.json")
    renderer = FrameRenderer(catalog, state)
    profile = StreamProfile(
        token="cached",
        path="cached",
        width=160,
        height=120,
        frame_rate=5,
        bitrate_kbps=128,
        key_frame_interval=5,
    )

    first = renderer.render(profile)
    unchanged = renderer.render(profile)
    state.absolute_move(PTZPosition(0.5, 0.0, 0.0))
    moved = renderer.render(profile)

    assert unchanged is first
    assert moved is not first


def test_pan_indicator_tracks_quarter_width_viewport() -> None:
    assert format_pan_indicator(-1.0, 0.25) == "[[--]------------]"
    assert format_pan_indicator(0.0, 0.25) == "[------[--]------]"
    assert format_pan_indicator(1.0, 0.25) == "[------------[--]]"
