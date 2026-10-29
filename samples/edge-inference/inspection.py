"""Inspection contracts, detection policies, and capture evidence validation."""

import hashlib
import json
import math
import os
import re
import stat
import struct
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

JsonObject = dict[str, Any]
SCENARIO_NAMES = ("pcb-quality", "equipment-area")
STAGES = ("trigger", "capture", "inference", "result")
MAX_MESSAGE_BYTES = 1024 * 1024
MAX_IMAGE_BYTES = 16 * 1024 * 1024


def encode(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def timestamp(value: object) -> float:
    if not isinstance(value, str):
        raise ValueError("Timestamp must be an ISO 8601 string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamp must include a time zone")
    return parsed.timestamp()


def utc(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def identifier(value: object) -> str:
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("trigger-id must be a canonical UUID")
    return value


def number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_scenarios(scenarios: list[JsonObject]) -> None:
    if not isinstance(scenarios, list) or not scenarios:
        raise ValueError("Configure at least one scenario")
    required = {
        "name",
        "deviceName",
        "assetName",
        "modelName",
        "topicPrefix",
        "confidenceThreshold",
        "imageSize",
        "outputRows",
        "classLabels",
        "policy",
    }
    for item in scenarios:
        if not isinstance(item, dict) or required - item.keys():
            raise ValueError(f"Each scenario requires: {', '.join(sorted(required))}")
        if item["name"] not in SCENARIO_NAMES:
            raise ValueError(f"Unknown scenario: {item['name']}")
        for key in ("deviceName", "assetName", "modelName"):
            value = item[key]
            if (
                not isinstance(value, str)
                or len(value) > 63
                or not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", value)
            ):
                raise ValueError(f"{key} must be a lowercase DNS label of at most 63 characters")
        prefix = item["topicPrefix"]
        if (
            not isinstance(prefix, str)
            or not prefix
            or prefix != prefix.strip("/")
            or "//" in prefix
            or any(character in prefix for character in "+#\x00")
            or any(character.isspace() for character in prefix)
        ):
            raise ValueError(
                "topicPrefix must contain nonempty topic levels without wildcards or whitespace"
            )
        if (
            not isinstance(item["confidenceThreshold"], str)
            or not 0 < float(item["confidenceThreshold"]) <= 1
        ):
            raise ValueError("confidenceThreshold must be a string representing a number in (0,1]")
        if item["imageSize"] != [640, 640]:
            raise ValueError("These model packages require a 640x640 coordinate space")
        if type(item["outputRows"]) is not int or item["outputRows"] != 300:
            raise ValueError("outputRows must be 300 for these packaged models")
        labels = item["classLabels"]
        if (
            not isinstance(labels, dict)
            or not labels
            or not all(
                isinstance(key, str)
                and key.isascii()
                and key.isdigit()
                and str(int(key)) == key
                and isinstance(value, str)
                and value
                for key, value in labels.items()
            )
        ):
            raise ValueError("classLabels must contain the packaged model's id2label mapping")
        policy = item["policy"]
        if not isinstance(policy, dict):
            raise ValueError("policy must be an object")
        if policy.get("type") == "defect-review":
            configured_labels = policy.get("labels")
            if (
                not isinstance(configured_labels, list)
                or not configured_labels
                or not all(isinstance(label, str) and label for label in configured_labels)
                or set(configured_labels) != set(labels.values())
            ):
                raise ValueError("Defect policy labels must match the packaged model's labels")
        elif policy.get("type") == "area-review":
            region = policy.get("region")
            if (
                not isinstance(region, list)
                or len(region) != 4
                or not all(number(v) for v in region)
            ):
                raise ValueError("Region must contain four finite coordinates")
            left, top, right, bottom = region
            if not 0 <= left < right <= 1 or not 0 <= top < bottom <= 1:
                raise ValueError("Region must be an ordered normalized rectangle in [0,1]")
            if policy.get("point") != "box-center" or policy.get("label") not in labels.values():
                raise ValueError("Area review requires a packaged model label and box-center point")
        else:
            raise ValueError(f"Unsupported policy: {policy.get('type')}")
    for key in ("name", "deviceName", "assetName", "modelName", "topicPrefix"):
        if len({item[key] for item in scenarios}) != len(scenarios):
            raise ValueError(f"Scenarios must have unique {key} values")


def select_snapshot(capture: object, scenario: JsonObject) -> tuple[JsonObject, list[object]]:
    if not isinstance(capture, dict) or not isinstance(capture.get("Result"), dict):
        raise ValueError(f"Capture failed: {encode(capture)}")
    result = capture["Result"]
    if result.get("SourceType") != "snapshot-to-fs":
        raise ValueError("Capture is not a snapshot-to-fs response")
    files = result.get("SourceFiles")
    if not isinstance(files, list) or not files:
        raise ValueError("Capture contains no snapshots")
    usable = []
    for item in files:
        if not isinstance(item, dict):
            raise ValueError("Malformed capture source file")
        offset = item.get("OffsetFromEventTimeMilliseconds")
        if (
            not number(offset)
            or not isinstance(item.get("TargetPath"), str)
            or not item.get("CopyStatus")
        ):
            raise ValueError("Capture lacks offset, target path or copy status")
        if item["CopyStatus"] in ("Copied", "Skipped"):
            usable.append(item)
    if not usable:
        raise ValueError("No snapshot was copied; inspect capture failures")
    selected = min(
        usable,
        key=lambda item: (
            abs(item["OffsetFromEventTimeMilliseconds"]),
            item["OffsetFromEventTimeMilliseconds"],
        ),
    )
    target = selected["TargetPath"]
    path = PurePosixPath(target)
    expected = (
        "recordings",
        scenario["deviceName"],
        "rtsp",
        scenario["assetName"],
        "camera-snapshots",
    )
    if (
        path.is_absolute()
        or "\\" in target
        or ".." in path.parts
        or path.parts[:-1] != expected
        or str(path) != target
        or path.suffix.lower() not in (".jpg", ".jpeg")
    ):
        raise ValueError(f"Snapshot path does not match the configured asset: {target}")
    warnings = []
    if capture.get("Error"):
        warnings.append(capture["Error"])
    if result.get("Failures"):
        warnings.extend(result["Failures"])
    if result.get("CoverageStatus") not in (None, "Full", "Complete"):
        warnings.append({"coverageStatus": result["CoverageStatus"]})
    return selected, warnings


def validate_detections(result: object) -> list[JsonObject]:
    if isinstance(result, dict) and "Error" in result:
        raise ValueError(f"Inference failed: {encode(result['Error'])}")
    if not isinstance(result, list) or len(result) > 300:
        raise ValueError(
            "Expected a YOLO postprocessor detection array, not a raw or legacy envelope"
        )
    for detection in result:
        if not isinstance(detection, dict):
            raise ValueError("Malformed detection")
        label, confidence, box = (detection.get(key) for key in ("label", "confidence", "box"))
        if not isinstance(label, str) or not label or label.startswith("class_"):
            raise ValueError("Detection has no model label; verify getModelInfo id2label")
        if not number(confidence) or not 0 <= confidence <= 1:
            raise ValueError("Detection confidence must be finite and in [0,1]")
        if (
            not isinstance(box, list)
            or len(box) != 4
            or not all(number(v) for v in box)
            or box[0] >= box[2]
            or box[1] >= box[3]
        ):
            raise ValueError("Detection box must contain finite, ordered xyxy coordinates")
    return result


def byte_path(item: object) -> str:
    if not isinstance(item, dict) or not isinstance(item.get("data"), list):
        raise ValueError("Inference input/output must contain a byte-array file reference")
    data = item["data"]
    if not 0 < len(data) <= 4096 or not all(
        type(value) is int and 0 <= value <= 255 for value in data
    ):
        raise ValueError("Invalid inference file-reference bytes")
    return bytes(data).decode("utf-8")


def float32(value: float) -> float:
    return struct.unpack("f", struct.pack("f", value))[0]


def audit_inference(
    envelope: object,
    scenario: JsonObject,
    responses: Path,
) -> tuple[list[JsonObject], str, JsonObject]:
    if not isinstance(envelope, dict) or set(envelope) != {"Result"}:
        raise ValueError(f"Inference did not succeed: {encode(envelope)}")
    result = envelope["Result"]
    if not isinstance(result, dict) or result.get("model") != scenario["modelName"]:
        raise ValueError("Inference envelope references the wrong model")
    if not number(result.get("inferenceTimeMs")) or result["inferenceTimeMs"] < 0:
        raise ValueError("Inference envelope has no valid execution time")
    input_path = byte_path(result.get("input"))
    filename = identifier(byte_path(result.get("output")))
    root_fd = os.open(responses, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
        with os.fdopen(fd, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("Inference tensor is not a regular file")
            data = source.read(MAX_MESSAGE_BYTES + 1)
    finally:
        os.close(root_fd)
    if len(data) > MAX_MESSAGE_BYTES:
        raise ValueError("Inference tensor exceeds 1 MiB")
    tensor = json.loads(data)
    if not isinstance(tensor, dict) or set(tensor) != {"detections_0"}:
        raise ValueError("Expected the packaged model's detections_0 tensor")
    batch = tensor["detections_0"]
    if not isinstance(batch, list) or len(batch) != 1 or not isinstance(batch[0], list):
        raise ValueError("Expected a single-batch detection tensor")
    if len(batch[0]) != scenario["outputRows"]:
        raise ValueError("Detection tensor row count differs from the packaged model")
    expected = []
    threshold = float32(float(scenario["confidenceThreshold"]))
    for row in batch[0]:
        if not isinstance(row, list) or len(row) != 6 or not all(number(v) for v in row):
            raise ValueError("Malformed tensor row; refusing a potentially misleading empty result")
        if (
            not 0 <= row[4] <= 1
            or row[5] != int(row[5])
            or str(int(row[5])) not in scenario["classLabels"]
        ):
            raise ValueError("Invalid tensor confidence or class ID")
        if any(not -(2**31) <= value < 2**31 for value in row[:4]):
            raise ValueError("Tensor coordinates exceed the postprocessor's integer range")
        confidence = float32(row[4])
        if confidence >= threshold:
            expected.append(
                {
                    "label": scenario["classLabels"][str(int(row[5]))],
                    "confidence": confidence,
                    "box": [int(float32(value)) for value in row[:4]],
                }
            )
    return (
        expected,
        input_path,
        {
            "timeMs": result["inferenceTimeMs"],
            "tensorFile": filename,
            "tensorSha256": hashlib.sha256(data).hexdigest(),
        },
    )


def check_postprocessing(detections: list[JsonObject], expected: list[JsonObject]) -> None:
    if len(detections) != len(expected):
        raise ValueError("Postprocessed detections disagree with the raw tensor")
    for actual, source in zip(detections, expected):
        if (
            actual["label"] != source["label"]
            or actual["box"] != source["box"]
            or not math.isclose(
                actual["confidence"], source["confidence"], rel_tol=1e-6, abs_tol=1e-7
            )
        ):
            raise ValueError(
                "Postprocessed labels, coordinates or confidence disagree with the raw tensor"
            )


def review_detections(scenario: JsonObject, detections: list[JsonObject]) -> list[JsonObject]:
    policy = scenario["policy"]
    threshold = float32(float(scenario["confidenceThreshold"]))
    if policy["type"] == "defect-review":
        if any(item["label"] not in policy["labels"] for item in detections):
            raise ValueError(
                "Unexpected PCB label; the graph may be using the wrong model or label cache"
            )
        return [item for item in detections if float32(item["confidence"]) >= threshold]
    if policy["type"] != "area-review":
        raise ValueError(f"Unsupported policy: {policy['type']}")
    width, height = scenario["imageSize"]
    left, top, right, bottom = policy["region"]
    matches = []
    for item in detections:
        x1, y1, x2, y2 = item["box"]
        x, y = (x1 + x2) / (2 * width), (y1 + y2) / (2 * height)
        if item["label"] == policy["label"] and float32(item["confidence"]) >= threshold:
            if left <= x <= right and top <= y <= bottom:
                matches.append(item)
    return matches


def preserve_image(root: Path, relative: str, destination: Path) -> JsonObject:
    """Open each component without following symlinks on the shared capture volume."""
    descriptors = [os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
    temporary = destination.with_suffix(".tmp")
    try:
        for part in PurePosixPath(relative).parts[:-1]:
            descriptors.append(
                os.open(
                    part,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=descriptors[-1],
                )
            )
        fd = os.open(
            PurePosixPath(relative).name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=descriptors[-1],
        )
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_IMAGE_BYTES:
                raise ValueError("Snapshot must be a nonempty regular file of at most 16 MiB")
            digest = hashlib.sha256()
            size = 0
            with temporary.open("wb") as target:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    size += len(block)
                    if size > MAX_IMAGE_BYTES:
                        raise ValueError("Snapshot grew beyond the evidence size limit")
                    digest.update(block)
                    target.write(block)
                target.flush()
                os.fsync(target.fileno())
        temporary.replace(destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return {"file": destination.name, "sha256": digest.hexdigest(), "bytes": size}
    finally:
        for fd in reversed(descriptors):
            os.close(fd)
        temporary.unlink(missing_ok=True)
