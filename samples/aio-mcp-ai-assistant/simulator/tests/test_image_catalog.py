from __future__ import annotations

from pathlib import Path

import pytest

from onvif_simulator.image_catalog import (
    CorruptImageError,
    ImageCatalog,
    ImageNotFoundError,
    InvalidImageNameError,
    UnsupportedImageError,
)


def test_switches_images_atomically(image_dir: Path) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")

    switched = catalog.switch("warehouse.png")

    assert switched.name == "warehouse.png"
    assert switched.revision == 1
    assert catalog.snapshot().image.getpixel((0, 0)) == (0, 0, 255)


@pytest.mark.parametrize(
    "name",
    ["", ".", "..", "../camera.jpg", "folder/camera.jpg", r"folder\camera.jpg"],
)
def test_rejects_paths(image_dir: Path, name: str) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")

    with pytest.raises(InvalidImageNameError):
        catalog.switch(name)


def test_failed_switch_preserves_active_image(image_dir: Path) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")

    with pytest.raises(CorruptImageError):
        catalog.switch("corrupt.jpg")

    assert catalog.active_name == "camera.jpg"
    assert catalog.revision == 0


def test_reports_missing_and_unsupported_images(image_dir: Path) -> None:
    catalog = ImageCatalog(image_dir, "camera.jpg")

    with pytest.raises(ImageNotFoundError):
        catalog.switch("missing.jpg")
    with pytest.raises(UnsupportedImageError):
        catalog.switch("notes.txt")
