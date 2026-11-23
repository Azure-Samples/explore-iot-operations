#!/usr/bin/env python3
"""Stage, publish, and verify one coordinated release of the two edge AI samples."""

import argparse
import gzip
import hashlib
import json
import os
import re
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((Path(__file__).with_name("release-spec.json")).read_text())
HOST = SPEC["registry"]
PREFIX = SPEC["repositoryPrefix"]
SOURCE = "https://github.com/Azure-Samples/explore-iot-operations"
INFERENCE = ROOT / "samples/edge-predictive-inference"
ASSISTANT = ROOT / "samples/aio-mcp-ai-assistant"
MODULE_TYPE = "application/vnd.module.wasm.content.layer.v1+wasm"
GRAPH_TYPE = "application/vnd.microsoft.aio.graph.v1+yaml"
MODEL_TYPE = "application/vnd.microsoft.foundry.model.v1"
STAGES = {
    "inference": ("preprocess", "postprocess"),
    "camera": ("get-status", "continuous-move", "stop"),
}
REPOSITORIES = {
    "inference": f"{PREFIX}/edge-predictive-inference",
    "camera": f"{PREFIX}/aio-mcp-ai-assistant/camera-actions",
}
IMAGES = {
    "assistant": f"{HOST}/{PREFIX}/aio-mcp-ai-assistant",
    "simulator": f"{HOST}/{PREFIX}/onvif-simulator",
}
VERSION = re.compile(
    r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
)
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def version(value: str) -> str:
    if len(value) > 128 or not VERSION.fullmatch(value):
        raise ValueError("Use a version such as 0.1.0-rc.1, without latest or build metadata")
    return value


def run(*arguments: str, cwd: Path | None = None) -> bytes:
    return subprocess.run(arguments, cwd=cwd, check=True, stdout=subprocess.PIPE).stdout


def digest_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def digest_file(path: Path, *, compressed: bool = False) -> str:
    hasher = hashlib.sha256()
    with gzip.open(path, "rb") if compressed else path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def labels(release_version: str, revision: str) -> dict[str, str]:
    return {
        "org.opencontainers.image.source": SOURCE,
        "org.opencontainers.image.revision": revision,
        "org.opencontainers.image.version": release_version,
        "org.opencontainers.image.url": f"{SOURCE}/tree/{revision}",
    }


def build_images(release_version: str) -> None:
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").decode().strip()
    run(
        "docker",
        "build",
        "--platform",
        SPEC["platform"],
        "--target",
        "test",
        str(ASSISTANT / "simulator"),
    )
    for name, context in (("assistant", ASSISTANT), ("simulator", ASSISTANT / "simulator")):
        reference = f"{IMAGES[name]}:{release_version}"
        run(
            "docker",
            "build",
            "--platform",
            SPEC["platform"],
            "--tag",
            reference,
            *(
                arg
                for key, value in labels(release_version, revision).items()
                for arg in ("--label", f"{key}={value}")
            ),
            str(context),
        )
        if name == "assistant":
            run("docker", "run", "--rm", "--network", "none", reference, "--help")
        else:
            run(
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "--entrypoint",
                "/app/.venv/bin/python",
                reference,
                "-c",
                "import onvif_simulator.app; import onvif_simulator.rtsp",
            )
    print("Built and smoke-checked both release images; nothing published.")


def validate_graph(graph: dict, family: str, stage: str, release_version: str) -> None:
    modules = [item["module"] for item in graph["operations"] if "module" in item]
    expected = f"{REPOSITORIES[family]}/{stage}:{release_version}"
    if modules != [expected] or graph["metadata"]["version"] != release_version:
        raise ValueError(f"{family}/{stage} must reference exactly its matching module: {expected}")


def image_config(archive: Path, reference: str, release_version: str, revision: str) -> bytes:
    with tarfile.open(archive) as saved:
        manifest_file = saved.extractfile("manifest.json")
        if manifest_file is None:
            raise ValueError("Docker archive has no manifest.json")
        manifests = json.load(manifest_file)
        if len(manifests) != 1 or manifests[0]["RepoTags"] != [reference]:
            raise ValueError(f"Expected exactly the tested image {reference}")
        config_file = saved.extractfile(manifests[0]["Config"])
        if config_file is None:
            raise ValueError("Docker archive has no image config")
        raw = config_file.read()
    config = json.loads(raw)
    expected_labels = labels(release_version, revision)
    if any(config["config"].get("Labels", {}).get(k) != v for k, v in expected_labels.items()):
        raise ValueError("Image labels do not match the candidate version and source revision")
    if (config["os"], config["architecture"]) != ("linux", "amd64"):
        raise ValueError("This release requires Linux/amd64 images")
    return raw


def stage(output: Path, release_version: str) -> None:
    from aio_mcp_ai_assistant.camera_graphs import graph as camera_graph

    inference_graph = runpy.run_path(str(INFERENCE / "render.py"))["graph"]
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD").decode().strip()
    timestamp = run("git", "-C", str(ROOT), "show", "-s", "--format=%cI", revision).decode().strip()
    dirty = bool(run("git", "-C", str(ROOT), "status", "--porcelain"))
    run(sys.executable, str(INFERENCE / "models/prepare.py"), "--check")
    output.mkdir(parents=True, exist_ok=False)
    artifacts = []
    for family, stages in STAGES.items():
        for name in stages:
            module = (
                INFERENCE / ".build" / f"{name}.wasm"
                if family == "inference"
                else ASSISTANT / ".build" / f"camera-{name}.wasm"
            )
            module_dir = output / "payloads" / f"{family}-{name}"
            module_dir.mkdir(parents=True)
            shutil.copyfile(module, module_dir / "module.wasm")
            artifacts.append(
                package(
                    output,
                    family,
                    name,
                    release_version,
                    revision,
                    timestamp,
                    MODULE_TYPE,
                    [("module.wasm", "application/wasm")],
                )
            )
            graph = (inference_graph if family == "inference" else camera_graph)(
                name, release_version, REPOSITORIES[family]
            )
            validate_graph(graph, family, name, release_version)
            graph_dir = output / "payloads" / f"{family}-{name}-graph"
            graph_dir.mkdir(parents=True)
            (graph_dir / "graph.yaml").write_text(yaml.safe_dump(graph, sort_keys=False))
            artifacts.append(
                package(
                    output,
                    family,
                    f"{name}-graph",
                    release_version,
                    revision,
                    timestamp,
                    GRAPH_TYPE,
                    [("graph.yaml", "application/yaml")],
                )
            )
    model_dir = output / "payloads/inference-yolox-nano"
    model_dir.mkdir(parents=True)
    model_files = [
        ("model.onnx", "application/octet-stream"),
        ("LICENSE-YOLOX", "text/plain"),
        ("provenance.json", "application/json"),
    ]
    for filename, _ in model_files:
        shutil.copyfile(INFERENCE / ".assets/model" / filename, model_dir / filename)
    artifacts.append(
        package(
            output,
            "inference",
            "yolox-nano",
            release_version,
            revision,
            timestamp,
            MODEL_TYPE,
            model_files,
        )
    )
    (output / "images").mkdir()
    images = []
    for name, repository in IMAGES.items():
        reference = f"{repository}:{release_version}"
        archive = output / "images" / f"{name}.tar"
        run("docker", "save", "--output", str(archive), reference)
        raw = image_config(archive, reference, release_version, revision)
        images.append(
            {
                "name": name,
                "repository": repository,
                "tagReference": reference,
                "archiveDigest": digest_file(archive),
                "configDigest": digest_bytes(raw),
            }
        )
    write_json(
        output / "release.json",
        {
            "schemaVersion": 1,
            "version": release_version,
            "revision": revision,
            "sourceDirty": dirty,
            "platform": SPEC["platform"],
            "artifacts": artifacts,
            "images": images,
            "runtimeValidated": False,
        },
    )
    candidate(output)
    print(f"Staged 11 OCI artifacts and two saved images in {output}; nothing published.")


def package(
    output: Path,
    family: str,
    name: str,
    release_version: str,
    revision: str,
    timestamp: str,
    media_type: str,
    files: list[tuple[str, str]],
) -> dict:
    identifier = f"{family}-{name}"
    directory = output / "payloads" / identifier
    (directory / "config.json").write_text("{}")
    layout = output / "layouts" / identifier
    layout.parent.mkdir(exist_ok=True)
    annotations = {
        **labels(release_version, revision),
        "org.opencontainers.image.created": timestamp,
    }
    run(
        "oras",
        "push",
        "--oci-layout",
        f"{layout}:{release_version}",
        "--image-spec",
        "v1.0",
        "--config",
        f"config.json:{media_type}",
        *(arg for key, value in annotations.items() for arg in ("--annotation", f"{key}={value}")),
        *(f"{filename}:{kind}" for filename, kind in files),
        cwd=directory,
    )
    descriptor = json.loads(
        run(
            "oras",
            "manifest",
            "fetch",
            "--oci-layout",
            f"{layout}:{release_version}",
            "--descriptor",
        )
    )
    repository = f"{HOST}/{REPOSITORIES[family]}/{name}"
    return {
        "name": identifier,
        "repository": repository,
        "tagReference": f"{repository}:{release_version}",
        "manifestDigest": descriptor["digest"],
        "mediaType": media_type,
        "payloads": [
            {"filename": filename, "digest": digest_file(directory / filename), "mediaType": kind}
            for filename, kind in files
        ],
    }


def metadata(directory: Path) -> dict:
    release = json.loads((directory / "release.json").read_text())
    release_version = version(release["version"])
    if (
        release["schemaVersion"] != 1
        or not re.fullmatch(r"[0-9a-f]{40}", release["revision"])
        or release["platform"] != SPEC["platform"]
        or release["runtimeValidated"] is not False
        or not isinstance(release["sourceDirty"], bool)
    ):
        raise ValueError("Unsupported candidate format or source revision")
    expected = {
        f"{family}-{stage}{suffix}": f"{HOST}/{REPOSITORIES[family]}/{stage}{suffix}"
        for family, stages in STAGES.items()
        for stage in stages
        for suffix in ("", "-graph")
    }
    expected["inference-yolox-nano"] = f"{HOST}/{REPOSITORIES['inference']}/yolox-nano"
    if (
        len(release["artifacts"]) != len(expected)
        or {item["name"]: item["repository"] for item in release["artifacts"]} != expected
        or len(release["images"]) != len(IMAGES)
        or {item["name"]: item["repository"] for item in release["images"]} != IMAGES
    ):
        raise ValueError("Incomplete or unexpected release artifact set")
    for item in [*release["artifacts"], *release["images"]]:
        if item["tagReference"] != f"{item['repository']}:{release_version}":
            raise ValueError("Candidate tags must all use the same release version")
    for item in release["artifacts"]:
        if item["name"] == "inference-yolox-nano":
            expected_type = MODEL_TYPE
            expected_files = {
                "model.onnx": "application/octet-stream",
                "LICENSE-YOLOX": "text/plain",
                "provenance.json": "application/json",
            }
        elif item["name"].endswith("-graph"):
            expected_type, expected_files = GRAPH_TYPE, {"graph.yaml": "application/yaml"}
        else:
            expected_type, expected_files = MODULE_TYPE, {"module.wasm": "application/wasm"}
        if (
            item["mediaType"] != expected_type
            or len(item["payloads"]) != len(expected_files)
            or {p["filename"]: p["mediaType"] for p in item["payloads"]} != expected_files
        ):
            raise ValueError(f"Incomplete or unexpected payloads: {item['name']}")
    return release


def candidate(directory: Path) -> dict:
    release = metadata(directory)
    release_version = release["version"]
    for item in release["artifacts"]:
        directory_path = directory / "payloads" / item["name"]
        layout = directory / "layouts" / item["name"]
        index = json.loads((layout / "index.json").read_text())
        manifests = index["manifests"]
        if (
            len(manifests) != 1
            or manifests[0]["digest"] != item["manifestDigest"]
            or manifests[0].get("annotations", {}).get("org.opencontainers.image.ref.name")
            != release_version
        ):
            raise ValueError(f"Local OCI layout changed: {item['name']}")
        raw = local_blob(layout, manifests[0]).read_bytes()
        manifest = check_existing(item, raw)
        if any(
            manifest.get("annotations", {}).get(k) != v
            for k, v in labels(release_version, release["revision"]).items()
        ):
            raise ValueError("OCI annotations differ from the candidate revision/version")
        for descriptor in [manifest["config"], *manifest["layers"]]:
            local_blob(layout, descriptor)
        for payload in item["payloads"]:
            filename = payload["filename"]
            if (
                Path(filename).name != filename
                or digest_file(directory_path / filename) != payload["digest"]
            ):
                raise ValueError(f"Candidate payload changed: {item['name']}/{filename}")
        if item["name"].endswith("-graph"):
            family, stage_name = item["name"].split("-", 1)
            validate_graph(
                yaml.safe_load((directory_path / "graph.yaml").read_text()),
                family,
                stage_name.removesuffix("-graph"),
                release_version,
            )
    for item in release["images"]:
        archive = directory / "images" / f"{item['name']}.tar"
        if digest_file(archive) != item["archiveDigest"]:
            raise ValueError("Saved image changed after staging")
        raw = image_config(archive, item["tagReference"], release_version, release["revision"])
        if digest_bytes(raw) != item["configDigest"]:
            raise ValueError("Saved image config differs from the candidate")
    return release


def local_blob(layout: Path, descriptor: dict) -> Path:
    digest = descriptor["digest"]
    if not DIGEST.fullmatch(digest):
        raise ValueError("Unsupported local blob digest")
    path = layout / "blobs/sha256" / digest.removeprefix("sha256:")
    if path.stat().st_size != descriptor["size"] or digest_file(path) != digest:
        raise ValueError("Local OCI blob content/size mismatch")
    return path


def remote_manifest(
    reference: str, *, auth: Path | None = None, missing_ok: bool = False
) -> bytes | None:
    result = subprocess.run(
        [
            "oras",
            "manifest",
            "fetch",
            *(["--registry-config", str(auth)] if auth else []),
            reference,
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout
    error = result.stderr.decode(errors="replace").strip()
    missing = re.search(
        r"\b(?:MANIFEST_UNKNOWN|NAME_UNKNOWN)\b|manifest unknown|name unknown", error, re.I
    )
    missing = missing or (
        error.startswith("Error response from registry: failed to fetch the content of ")
        and error.endswith(f"{reference}: not found")
    )
    if missing_ok and missing:
        return None
    raise ValueError(f"Cannot retrieve {reference}: {error}")


def check_existing(item: dict, raw: bytes, *, image: bool = False) -> dict:
    manifest = json.loads(raw)
    if image:
        if (
            manifest.get("schemaVersion") != 2
            or manifest.get("config", {}).get("digest") != item["configDigest"]
            or not manifest.get("layers")
        ):
            raise ValueError(f"Immutable image tag conflict: {item['tagReference']}")
    else:
        if digest_bytes(raw) != item["manifestDigest"]:
            raise ValueError(f"Immutable artifact tag conflict: {item['tagReference']}")
        if manifest["config"]["mediaType"] != item["mediaType"]:
            raise ValueError("Artifact config media type differs")
        expected = {p["filename"]: (p["digest"], p["mediaType"]) for p in item["payloads"]}
        actual = {
            d.get("annotations", {}).get("org.opencontainers.image.title"): (
                d["digest"],
                d["mediaType"],
            )
            for d in manifest["layers"]
        }
        if len(manifest["layers"]) != len(expected) or actual != expected:
            raise ValueError("Artifact payloads differ from the candidate")
    return manifest


def publish(directory: Path, expected_version: str, expected_revision: str) -> None:
    (directory / "verification.json").unlink(missing_ok=True)
    release = candidate(directory)
    if (
        release["sourceDirty"]
        or release["version"] != expected_version
        or release["revision"] != expected_revision
    ):
        raise ValueError(
            "Publish only the clean candidate from this exact workflow revision/version"
        )
    # Check the whole set before the first write. The workflow serializes publishers.
    for item in [*release["artifacts"], *release["images"]]:
        raw = remote_manifest(item["tagReference"], missing_ok=True)
        if raw is not None:
            check_existing(item, raw, image=item in release["images"])
    for item in release["artifacts"]:
        layout = directory / "layouts" / item["name"]
        raw = run("oras", "manifest", "fetch", "--oci-layout", f"{layout}:{release['version']}")
        check_existing(item, raw)
        existing = remote_manifest(item["tagReference"], missing_ok=True)
        if existing is None:
            run(
                "oras",
                "cp",
                "--from-oci-layout",
                f"{layout}:{release['version']}",
                item["tagReference"],
            )
        else:
            check_existing(item, existing)
    for item in release["images"]:
        existing = remote_manifest(item["tagReference"], missing_ok=True)
        if existing is None:
            run("docker", "load", "--input", str(directory / "images" / f"{item['name']}.tar"))
            loaded = json.loads(run("docker", "image", "inspect", item["tagReference"]))[0]
            config_digest = (
                loaded.get("Descriptor", {})
                .get("annotations", {})
                .get("config.digest", loaded["Id"])
            )
            if config_digest != item["configDigest"]:
                raise ValueError("Loaded image differs from the saved candidate")
            run("docker", "push", item["tagReference"])
        else:
            check_existing(item, existing, image=True)
    verify(directory)


def verify(directory: Path, *, published: bool = False) -> None:
    marker = directory / "verification.json"
    marker.unlink(missing_ok=True)
    release = metadata(directory) if published else candidate(directory)
    if published and release["sourceDirty"]:
        raise ValueError("Published releases must identify a clean source revision")
    verified = []
    with tempfile.TemporaryDirectory(prefix="anonymous-pull-") as temporary:
        temporary_path = Path(temporary)
        auth = temporary_path / "auth.json"
        write_json(auth, {"auths": {}})
        for image, items in ((False, release["artifacts"]), (True, release["images"])):
            for item in items:
                raw = remote_manifest(item["tagReference"], auth=auth)
                if raw is None:
                    raise ValueError("Missing published manifest")
                manifest = check_existing(item, raw, image=image)
                blobs = []
                for descriptor in [manifest["config"], *manifest["layers"]]:
                    digest = descriptor["digest"]
                    if not DIGEST.fullmatch(digest):
                        raise ValueError("Unsupported blob digest")
                    path = temporary_path / digest.replace(":", "-")
                    run(
                        "oras",
                        "blob",
                        "fetch",
                        "--registry-config",
                        str(auth),
                        f"{item['repository']}@{digest}",
                        "--output",
                        str(path),
                    )
                    if path.stat().st_size != descriptor["size"] or digest_file(path) != digest:
                        raise ValueError(f"Published blob content/size mismatch: {digest}")
                    blobs.append(path)
                if image:
                    config = json.loads(blobs[0].read_bytes())
                    if any(
                        config["config"].get("Labels", {}).get(k) != v
                        for k, v in labels(release["version"], release["revision"]).items()
                    ):
                        raise ValueError("Published image labels differ from the release")
                    diff_ids = config["rootfs"]["diff_ids"]
                    if len(diff_ids) != len(manifest["layers"]):
                        raise ValueError("Image layer count differs from the tested image")
                    for path, descriptor, diff_id in zip(
                        blobs[1:], manifest["layers"], diff_ids, strict=True
                    ):
                        kind = descriptor["mediaType"]
                        compressed = kind.endswith(("+gzip", ".gzip"))
                        if not compressed and not kind.endswith(".tar"):
                            raise ValueError(f"Unsupported image layer format: {kind}")
                        if digest_file(path, compressed=compressed) != diff_id:
                            raise ValueError(
                                "Published image layer differs from the tested root filesystem"
                            )
                elif item["name"].endswith("-graph"):
                    family, stage_name = item["name"].split("-", 1)
                    validate_graph(
                        yaml.safe_load(blobs[1].read_text()),
                        family,
                        stage_name.removesuffix("-graph"),
                        release["version"],
                    )
                verified.append(
                    {
                        "name": item["name"],
                        "tagReference": item["tagReference"],
                        "digestReference": f"{item['repository']}@{digest_bytes(raw)}",
                        "manifestDigest": digest_bytes(raw),
                    }
                )
    write_json(
        marker,
        {
            "schemaVersion": 1,
            "version": release["version"],
            "revision": release["revision"],
            "anonymousFullPullVerified": True,
            "runtimeValidated": False,
            "artifacts": verified,
        },
    )
    print(
        "All 13 artifacts passed anonymous full-content verification. Cluster validation is pending."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    staging = commands.add_parser("stage")
    staging.add_argument("--version", type=version, default=SPEC["version"])
    staging.add_argument("--output", type=Path, required=True)
    building = commands.add_parser("build-images")
    building.add_argument("--version", type=version, default=SPEC["version"])
    for command in ("publish", "verify"):
        child = commands.add_parser(command)
        child.add_argument("candidate", type=Path)
        if command == "publish":
            child.add_argument("--version", type=version, required=True)
            child.add_argument("--revision", required=True)
        else:
            child.add_argument(
                "--published",
                action="store_true",
                help="Verify downloaded release.json without local build outputs or image archives",
            )
    args = parser.parse_args()
    try:
        if args.command == "stage":
            stage(args.output.resolve(), args.version)
        elif args.command == "build-images":
            build_images(args.version)
        elif args.command == "publish":
            if not os.environ.get("DOCKER_CONFIG"):
                raise ValueError("Set DOCKER_CONFIG to an isolated registry credential directory")
            publish(args.candidate.resolve(), args.version, args.revision)
        else:
            verify(args.candidate.resolve(), published=args.published)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
