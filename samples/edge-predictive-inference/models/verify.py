#!/usr/bin/env python3
"""Run real local ONNX inference using the same Rust pre/postprocessing as the graph."""

import argparse
import json
import subprocess
import uuid
from pathlib import Path

import numpy as np
import onnxruntime as ort
from prepare import MODEL_DIRECTORY, ROOT, check_model


def verify(image: Path, output: Path) -> dict:
    model = MODEL_DIRECTORY / "model.onnx"
    check_model(model)
    helper = ROOT / ".build" / "target" / "release" / "examples" / "pipeline"
    if not helper.is_file():
        raise ValueError("Run ./build.sh before local verification")
    prepared = json.loads(
        subprocess.check_output(
            [str(helper), "prepare", str(image.resolve()), str(output.resolve())], text=True
        )
    )
    tensor = np.asarray(json.loads(Path(prepared["request"]).read_text()), dtype=np.float32)
    if tensor.shape != (1, 3, 416, 416):
        raise ValueError(f"Unexpected prepared tensor shape: {tensor.shape}")
    session = ort.InferenceSession(str(model), providers=["CPUExecutionProvider"])
    prediction = session.run(["output"], {"images": tensor})[0]
    response = output / str(uuid.uuid4())
    response.write_text(json.dumps({"output_0": prediction.tolist()}, allow_nan=False))
    observation = json.loads(
        subprocess.check_output(
            [str(helper), "finish", prepared["context"], str(response.resolve())], text=True
        )
    )
    (output / f"{observation['frameId']}.observation.json").write_text(
        json.dumps(observation, indent=2, allow_nan=False) + "\n"
    )
    return observation


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path, help="An authorized JPEG image")
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "local-inference")
    args = parser.parse_args()
    try:
        observation = verify(args.image, args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Local inference failed: {error}\n")
    print(json.dumps(observation, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
