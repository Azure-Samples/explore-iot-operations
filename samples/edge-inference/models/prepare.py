"""Download verified ONNX baselines and adapt them to Foundry Local's image API."""

import argparse
import gzip
import hashlib
import json
import shutil
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 3, 1, 1)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 3, 1, 1)
LICENSE_URL = "https://www.gnu.org/licenses/agpl-3.0.txt"
LICENSE_SHA256 = "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0"
FACTORY_URL = (
    "https://upload.wikimedia.org/wikipedia/commons/5/5c/"
    "Employees_working_at_Edison_Price_Lighting.jpg"
)
FACTORY_SHA256 = "fbda4b9ab58d03e13885f66f807a21795edb7a8d845179abd3b3af97b750c234"


def sha256(path):
    with path.open("rb") as source:
        return _hash_stream(source)


def _hash_stream(source):
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def download(url, destination, expected):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256(destination) != expected:
            raise ValueError(f"Checksum mismatch: {destination}; remove it before retrying")
        return
    temporary = destination.with_suffix(destination.suffix + ".download")
    request = urllib.request.Request(
        url, headers={"User-Agent": "Azure-IoT-edge-inference-sample/1"}
    )
    try:
        with (
            urllib.request.urlopen(request, timeout=120) as response,
            temporary.open("wb") as target,
        ):
            shutil.copyfileobj(response, target)
        if sha256(temporary) != expected:
            raise ValueError(f"Checksum mismatch downloading {url}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def adapt_model(source, target):
    model = onnx.load(source, load_external_data=False)
    if any(item.data_location == onnx.TensorProto.EXTERNAL for item in model.graph.initializer):
        raise ValueError("Only self-contained ONNX models are supported")
    if len(model.graph.input) != 1 or len(model.graph.output) != 1:
        raise ValueError("Expected exactly one input and one output")
    input_info = model.graph.input[0]
    shape = [dimension.dim_value for dimension in input_info.type.tensor_type.shape.dim]
    if shape != [1, 3, 640, 640] or input_info.type.tensor_type.elem_type != onnx.TensorProto.FLOAT:
        raise ValueError(f"Expected float32 NCHW [1,3,640,640], received {shape}")
    output_info = model.graph.output[0]
    output_shape = [dimension.dim_value for dimension in output_info.type.tensor_type.shape.dim]
    if (
        output_shape != [1, 300, 6]
        or output_info.type.tensor_type.elem_type != onnx.TensorProto.FLOAT
    ):
        raise ValueError(
            f"Expected float32 end-to-end [1,300,6] detections, received {output_shape}"
        )

    names = {name for node in model.graph.node for name in (*node.input, *node.output)}
    added = {"foundry_image", "edge_scaled", "edge_mean", "edge_std", "detections"}
    if names & added:
        raise ValueError("Adapter tensor names collide with the source model")

    original_input = input_info.name
    input_info.name = "foundry_image"
    # Foundry's image API applies ImageNet normalization; YOLO expects RGB in [0,1].
    prefix = [
        helper.make_node("Mul", ["foundry_image", "edge_std"], ["edge_scaled"]),
        helper.make_node("Add", ["edge_scaled", "edge_mean"], [original_input]),
    ]
    nodes = prefix + list(model.graph.node)
    nodes.append(helper.make_node("Identity", [output_info.name], ["detections"]))
    output_info.name = "detections"
    del model.graph.node[:]
    model.graph.node.extend(nodes)
    model.graph.initializer.extend(
        [
            numpy_helper.from_array(MEAN, "edge_mean"),
            numpy_helper.from_array(STD, "edge_std"),
        ]
    )
    onnx.checker.check_model(model)
    onnx.save(model, target)


def letterbox(source, destination):
    with Image.open(source) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
        canvas = ImageOps.pad(
            image,
            (640, 640),
            method=Image.Resampling.BILINEAR,
            color=(114, 114, 114),
            centering=(0.5, 0.5),
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(destination, "JPEG", quality=95)


def verify_adapter(original, adapted, image_path):
    with Image.open(image_path) as image:
        if image.size != (640, 640):
            raise ValueError("Smoke-test images must first be letterboxed to 640x640")
        rgb = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    tensor = rgb.transpose(2, 0, 1)[None]
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    baseline = ort.InferenceSession(str(original), options, providers=["CPUExecutionProvider"])
    served = ort.InferenceSession(str(adapted), options, providers=["CPUExecutionProvider"])
    expected = baseline.run(None, {baseline.get_inputs()[0].name: tensor})[0]
    actual = served.run(None, {"foundry_image": (tensor - MEAN) / STD})[0]
    if not np.isfinite(actual).all() or actual.shape[-1] != 6:
        raise ValueError("Model returned invalid detections")
    # Tiny numerical differences in the adapter can reorder low-confidence rows.
    expected = expected[0][expected[0, :, 4] >= 0.55]
    selected = actual[0][actual[0, :, 4] >= 0.55]

    def sort_key(rows):
        return rows[np.lexsort((rows[:, 0], rows[:, 5]))]

    np.testing.assert_allclose(sort_key(selected), sort_key(expected), rtol=0.002, atol=0.02)
    return actual


def prepare(args):
    if not args.acknowledge_third_party_licenses:
        raise ValueError("Read THIRD-PARTY-NOTICES.md and pass --acknowledge-third-party-licenses")
    catalog = json.loads((ROOT / "models/catalog.json").read_text())
    selected = catalog if args.scenario == "all" else {args.scenario: catalog[args.scenario]}
    for scenario, metadata in selected.items():
        folder = args.output / scenario
        source = folder / "source.onnx"
        base = f"https://huggingface.co/{metadata['repository']}/resolve/{metadata['revision']}/"
        download(base + metadata["file"], source, metadata["sha256"])
        package = folder / "package"
        package.mkdir(parents=True, exist_ok=True)
        if "id2label" in metadata:
            labels = metadata["id2label"]
        else:
            config = folder / "source-config.json"
            download(base + metadata["configFile"], config, metadata["configSha256"])
            labels = json.loads(config.read_text())["id2label"]
        if not labels or sorted(int(key) for key in labels) != list(range(len(labels))):
            raise ValueError("Model labels must be a contiguous id2label map")
        adapt_model(source, package / "model.onnx")
        (package / "config.json").write_text(json.dumps({"id2label": labels}, indent=2) + "\n")
        download(LICENSE_URL, package / "LICENSE", LICENSE_SHA256)
        shutil.copyfile(__file__, package / "prepare.py")
        provenance = {
            **metadata,
            "modifications": "Undo Foundry ImageNet normalization; name output detections.",
            "outputTensorKey": "detections_0",
            "packagedModelSha256": sha256(package / "model.onnx"),
            "packagedConfigSha256": sha256(package / "config.json"),
            "imagePreprocessing": "640x640 RGB; ImageNet normalization by Foundry image API",
        }
        (package / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        archive = folder / "model.tar.gz"
        with (
            archive.open("wb") as target,
            gzip.GzipFile(fileobj=target, mode="wb", filename="", mtime=0) as compressed,
        ):
            with tarfile.open(fileobj=compressed, mode="w") as tar:
                for name in (
                    "LICENSE",
                    "config.json",
                    "model.onnx",
                    "prepare.py",
                    "provenance.json",
                ):
                    path = package / name
                    info = tar.gettarinfo(path, arcname=name)
                    info.mtime = info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mode = 0o644
                    with path.open("rb") as source_file:
                        tar.addfile(info, source_file)
        print(
            json.dumps({"scenario": scenario, "archive": str(archive), "sha256": sha256(archive)})
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("prepare")
    package.add_argument(
        "--scenario", choices=["all", "pcb-quality", "equipment-area"], default="all"
    )
    package.add_argument("--output", type=Path, default=ROOT / ".assets/models")
    package.add_argument("--acknowledge-third-party-licenses", action="store_true")
    fixture = commands.add_parser("factory-image")
    fixture.add_argument("--output", type=Path, default=ROOT / ".assets/replay")
    image = commands.add_parser("letterbox")
    image.add_argument("source", type=Path)
    image.add_argument("destination", type=Path)
    smoke = commands.add_parser("smoke")
    smoke.add_argument("--scenario", required=True, choices=["pcb-quality", "equipment-area"])
    smoke.add_argument("--image", required=True, type=Path)
    smoke.add_argument("--models", type=Path, default=ROOT / ".assets/models")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
    elif args.command == "factory-image":
        original = args.output / "factory-original.jpg"
        download(FACTORY_URL, original, FACTORY_SHA256)
        letterbox(original, args.output / "equipment-area.jpg")
        print(
            "CC BY-SA 3.0: Mizzvizz9 / Wikimedia Commons. Resized and padded; see THIRD-PARTY-NOTICES.md."
        )
    elif args.command == "letterbox":
        letterbox(args.source, args.destination)
    else:
        folder = args.models / args.scenario
        output = verify_adapter(folder / "source.onnx", folder / "package/model.onnx", args.image)
        labels = json.loads((folder / "package/config.json").read_text())["id2label"]
        detections = [
            {
                "label": labels[str(int(row[5]))],
                "confidence": float(row[4]),
                "box": row[:4].tolist(),
            }
            for row in output[0]
            if row[4] >= 0.55
        ]
        print(json.dumps({"adapterEquivalent": True, "detections": detections}, indent=2))


if __name__ == "__main__":
    main()
