#!/usr/bin/env python3
"""Download and verify the unmodified upstream YOLOX-Nano ONNX export."""

import argparse
import hashlib
import json
import os
import tempfile
import urllib.request
from pathlib import Path

import onnx

ROOT = Path(__file__).resolve().parents[1]
MODEL_URL = (
    "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx"
)
MODEL_SHA256 = "c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d"
LICENSE_URL = "https://raw.githubusercontent.com/Megvii-BaseDetection/YOLOX/0.1.1rc0/LICENSE"
LICENSE_SHA256 = "577c03d505ec80f667ebf96ebd0cc4f6825c817ca1088ee348c48aaabd51bd92"
MODEL_DIRECTORY = ROOT / ".assets" / "model"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url: str, destination: Path, limit: int, expected_hash: str | None = None) -> None:
    if destination.exists():
        if expected_hash and sha256(destination) != expected_hash:
            raise ValueError(
                f"Existing {destination} has an unexpected checksum; use a clean asset directory"
            )
        return
    descriptor, temporary = tempfile.mkstemp(dir=destination.parent)
    temporary = Path(temporary)
    try:
        with (
            os.fdopen(descriptor, "wb") as target,
            urllib.request.urlopen(url, timeout=60) as source,
        ):
            size = 0
            while chunk := source.read(1024 * 1024):
                size += len(chunk)
                if size > limit:
                    raise ValueError(f"Download exceeds the expected maximum size: {url}")
                target.write(chunk)
        if expected_hash and sha256(temporary) != expected_hash:
            raise ValueError(f"Downloaded model checksum does not match {expected_hash}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def check_model(path: Path) -> None:
    if sha256(path) != MODEL_SHA256:
        raise ValueError("YOLOX-Nano model checksum does not match the reviewed upstream export")
    onnx.checker.check_model(str(path))
    model = onnx.load(path, load_external_data=False)
    for actual, name, shape in [
        (model.graph.input, "images", [1, 3, 416, 416]),
        (model.graph.output, "output", [1, 3549, 85]),
    ]:
        if len(actual) != 1:
            raise ValueError("Expected exactly one model input and output")
        tensor = actual[0].type.tensor_type
        if (
            actual[0].name != name
            or tensor.elem_type != onnx.TensorProto.FLOAT
            or [dimension.dim_value for dimension in tensor.shape.dim] != shape
        ):
            raise ValueError(f"Unexpected {name} tensor contract; expected FP32 {shape}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="Verify existing assets without downloading"
    )
    args = parser.parse_args()
    try:
        if not args.check:
            MODEL_DIRECTORY.mkdir(parents=True, exist_ok=True)
            download(MODEL_URL, MODEL_DIRECTORY / "model.onnx", 20 * 1024 * 1024, MODEL_SHA256)
            download(LICENSE_URL, MODEL_DIRECTORY / "LICENSE-YOLOX", 128 * 1024, LICENSE_SHA256)
        check_model(MODEL_DIRECTORY / "model.onnx")
        if sha256(MODEL_DIRECTORY / "LICENSE-YOLOX") != LICENSE_SHA256:
            raise ValueError("Missing or unexpected upstream Apache-2.0 license")
        provenance = {
            "source": MODEL_URL,
            "sha256": MODEL_SHA256,
            "license": "Apache-2.0",
            "licenseSha256": LICENSE_SHA256,
            "input": {"name": "images", "shape": [1, 3, 416, 416], "type": "float32"},
            "output": {"name": "output", "shape": [1, 3549, 85], "type": "float32"},
        }
        if args.check:
            if json.loads((MODEL_DIRECTORY / "provenance.json").read_text()) != provenance:
                raise ValueError("Model provenance does not match the packaged model")
        else:
            (MODEL_DIRECTORY / "provenance.json").write_text(
                json.dumps(provenance, indent=2) + "\n"
            )
    except (OSError, ValueError, onnx.checker.ValidationError) as error:
        parser.exit(1, f"Model preparation failed: {error}\n")
    print(
        f"Verified the upstream model, tensor contract, license, and provenance in {MODEL_DIRECTORY}"
    )


if __name__ == "__main__":
    main()
