from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from threading import RLock

from PIL import Image, UnidentifiedImageError

SUPPORTED_EXTENSIONS = {".bmp", ".jpeg", ".jpg", ".png", ".webp"}


class ImageCatalogError(ValueError):
    pass


class InvalidImageNameError(ImageCatalogError):
    pass


class ImageNotFoundError(ImageCatalogError):
    pass


class UnsupportedImageError(ImageCatalogError):
    pass


class CorruptImageError(ImageCatalogError):
    pass


@dataclass(frozen=True)
class ImageSnapshot:
    name: str
    image: Image.Image
    revision: int


class ImageCatalog:
    def __init__(self, image_dir: Path, initial_image: str) -> None:
        self._image_dir = image_dir.resolve()
        self._lock = RLock()
        self._name = ""
        self._image = Image.new("RGB", (1, 1), "black")
        self._revision = 0
        name, image = self._load_candidate(initial_image)
        self._name = name
        self._image = image

    @property
    def active_name(self) -> str:
        with self._lock:
            return self._name

    @property
    def revision(self) -> int:
        with self._lock:
            return self._revision

    def available_images(self) -> list[str]:
        try:
            entries = self._image_dir.iterdir()
        except OSError as exc:
            raise ImageCatalogError(
                f"unable to read image directory {self._image_dir}: {exc}"
            ) from exc
        return sorted(
            entry.name
            for entry in entries
            if entry.is_file() and entry.suffix.lower() in SUPPORTED_EXTENSIONS
        )

    def snapshot(self) -> ImageSnapshot:
        with self._lock:
            return ImageSnapshot(self._name, self._image, self._revision)

    def switch(self, requested_name: str) -> ImageSnapshot:
        name, image = self._load_candidate(requested_name)
        with self._lock:
            if name != self._name:
                self._name = name
                self._image = image
                self._revision += 1
            return ImageSnapshot(self._name, self._image, self._revision)

    def _load_candidate(self, requested_name: str) -> tuple[str, Image.Image]:
        name = self._validate_name(requested_name)
        candidate = self._image_dir / name
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError as exc:
            raise ImageNotFoundError(f"image {name!r} does not exist") from exc
        except OSError as exc:
            raise ImageCatalogError(f"unable to resolve image {name!r}: {exc}") from exc

        if resolved.parent != self._image_dir or not resolved.is_file():
            raise InvalidImageNameError("image must be a file directly inside the image directory")
        if resolved.suffix.lower() not in SUPPORTED_EXTENSIONS:
            raise UnsupportedImageError(f"unsupported image extension {resolved.suffix!r}")

        try:
            with Image.open(resolved) as opened:
                opened.verify()
            with Image.open(resolved) as opened:
                image = opened.convert("RGB")
                image.load()
        except UnidentifiedImageError as exc:
            raise CorruptImageError(f"unable to decode image {name!r}: {exc}") from exc
        except (OSError, ValueError) as exc:
            raise CorruptImageError(f"unable to decode image {name!r}: {exc}") from exc
        return name, image

    @staticmethod
    def _validate_name(requested_name: str) -> str:
        if (
            not requested_name
            or requested_name in {".", ".."}
            or Path(requested_name).name != requested_name
            or "/" in requested_name
            or "\\" in requested_name
            or "\x00" in requested_name
        ):
            raise InvalidImageNameError(
                "image name must identify a file directly inside the image directory"
            )
        return requested_name
