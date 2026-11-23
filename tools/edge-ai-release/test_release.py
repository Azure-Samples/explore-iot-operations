import copy
import gzip
import io
import json
import runpy
import subprocess
import tarfile
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

import release

REVISION = "a" * 40


@pytest.mark.parametrize("family,stages", release.STAGES.items())
def test_generated_graphs_resolve_only_matching_release_modules(family, stages):
    from aio_mcp_ai_assistant.camera_graphs import graph as camera_graph

    inference_graph = runpy.run_path(str(release.INFERENCE / "render.py"))["graph"]
    factory = inference_graph if family == "inference" else camera_graph
    for stage in stages:
        graph = factory(stage, "1.2.3-rc.1", release.REPOSITORIES[family])
        release.validate_graph(graph, family, stage, "1.2.3-rc.1")
        for changed in (
            f"{release.REPOSITORIES[family]}/{stage}:1.2.2",
            f"other-repository/{stage}:1.2.3-rc.1",
        ):
            broken = copy.deepcopy(graph)
            broken["operations"][1]["module"] = changed
            with pytest.raises(ValueError, match="matching module"):
                release.validate_graph(broken, family, stage, "1.2.3-rc.1")


@pytest.mark.parametrize("bad_version", ["latest", "1.2", "1.2.3/other", "01.2.3", "1.2.3\n"])
def test_rejects_mutable_or_ambiguous_release_versions(bad_version):
    with pytest.raises(ValueError):
        release.version(bad_version)


@pytest.mark.parametrize(
    "message",
    [
        "401 Unauthorized",
        "403 Forbidden",
        "context deadline exceeded",
        "proxy configuration not found",
        "Error response from registry: failed to fetch the content of other/ref: not found",
    ],
)
def test_registry_errors_are_not_tag_absence(message):
    with (
        patch.object(
            release.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 1, b"", message.encode()),
        ),
        pytest.raises(ValueError, match="Cannot retrieve"),
    ):
        release.remote_manifest("ghcr.io/example/module:1.2.3", missing_ok=True)


def test_registry_tag_absence_requires_the_exact_reference():
    reference = "ghcr.io/example/module:1.2.3"
    result = subprocess.CompletedProcess(
        [],
        1,
        b"",
        f"Error response from registry: failed to fetch the content of {reference}: not found".encode(),
    )
    with patch.object(release.subprocess, "run", return_value=result):
        assert release.remote_manifest(reference, missing_ok=True) is None
        with pytest.raises(ValueError):
            release.remote_manifest(reference)


def save_image(path, reference, *, revision=REVISION):
    layer = b"unit-test-image-layer"
    config = json.dumps(
        {
            "os": "linux",
            "architecture": "amd64",
            "config": {"Labels": release.labels("1.2.3", revision)},
            "rootfs": {"diff_ids": [release.digest_bytes(layer)]},
        }
    ).encode()
    manifest = json.dumps(
        [{"RepoTags": [reference], "Config": "config.json", "Layers": ["layer.tar"]}]
    ).encode()
    with tarfile.open(path, "w") as archive:
        for name, data in (
            ("manifest.json", manifest),
            ("config.json", config),
            ("layer.tar", layer),
        ):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return config


def test_saved_images_are_bound_to_source_revision_and_tag(tmp_path):
    archive = tmp_path / "image.tar"
    reference = f"{release.IMAGES['assistant']}:1.2.3"
    config = save_image(archive, reference)
    assert release.image_config(archive, reference, "1.2.3", REVISION) == config
    with pytest.raises(ValueError, match="exactly the tested image"):
        release.image_config(archive, reference.replace("1.2.3", "latest"), "1.2.3", REVISION)
    with pytest.raises(ValueError, match="source revision"):
        release.image_config(archive, reference, "1.2.3", "b" * 40)


def test_existing_image_with_different_content_is_never_replaced():
    image = {"configDigest": "sha256:" + "a" * 64, "tagReference": "ghcr.io/example/image:1.2.3"}
    changed = json.dumps({"config": {"digest": "sha256:" + "b" * 64}, "layers": [{}]}).encode()
    with pytest.raises(ValueError, match="Immutable image tag conflict"):
        release.check_existing(image, changed, image=True)


@pytest.fixture
def candidate(tmp_path):
    artifacts = []
    for family, stages in release.STAGES.items():
        for stage in stages:
            for suffix in ("", "-graph"):
                name = f"{family}-{stage}{suffix}"
                repository = f"{release.HOST}/{release.REPOSITORIES[family]}/{stage}{suffix}"
                if suffix:
                    data = yaml.safe_dump(
                        {
                            "metadata": {"version": "1.2.3"},
                            "operations": [
                                {"module": f"{release.REPOSITORIES[family]}/{stage}:1.2.3"}
                            ],
                        }
                    ).encode()
                    filename, kind, config_kind = (
                        "graph.yaml",
                        "application/yaml",
                        release.GRAPH_TYPE,
                    )
                else:
                    data, filename, kind, config_kind = (
                        b"unit-test-payload",
                        "module.wasm",
                        "application/wasm",
                        release.MODULE_TYPE,
                    )
                artifacts.append(
                    make_layout(tmp_path, name, repository, filename, kind, config_kind, data)
                )
    artifacts.append(
        make_layout(
            tmp_path,
            "inference-yolox-nano",
            f"{release.HOST}/{release.REPOSITORIES['inference']}/yolox-nano",
            "model.onnx",
            "application/octet-stream",
            release.MODEL_TYPE,
            b"unit-test-model",
            additional_files=[
                ("LICENSE-YOLOX", "text/plain", b"unit-test-license"),
                ("provenance.json", "application/json", b"{}"),
            ],
        )
    )
    images = []
    (tmp_path / "images").mkdir()
    for name, repository in release.IMAGES.items():
        archive = tmp_path / "images" / f"{name}.tar"
        raw = save_image(archive, f"{repository}:1.2.3")
        images.append(
            {
                "name": name,
                "repository": repository,
                "tagReference": f"{repository}:1.2.3",
                "archiveDigest": release.digest_file(archive),
                "configDigest": release.digest_bytes(raw),
            }
        )
    release.write_json(
        tmp_path / "release.json",
        {
            "schemaVersion": 1,
            "version": "1.2.3",
            "revision": REVISION,
            "platform": "linux/amd64",
            "sourceDirty": False,
            "runtimeValidated": False,
            "artifacts": artifacts,
            "images": images,
        },
    )
    return tmp_path


def make_layout(root, name, repository, filename, kind, config_kind, data, additional_files=None):
    payload = root / "payloads" / name
    payload.mkdir(parents=True)
    blobs = root / "layouts" / name / "blobs/sha256"
    blobs.mkdir(parents=True)

    def blob(content, media_type, **extra):
        digest = release.digest_bytes(content)
        (blobs / digest.removeprefix("sha256:")).write_bytes(content)
        return {"digest": digest, "size": len(content), "mediaType": media_type, **extra}

    layers = []
    files = [(filename, kind, data), *(additional_files or [])]
    for payload_name, payload_kind, content in files:
        (payload / payload_name).write_bytes(content)
        layers.append(
            blob(
                content, payload_kind, annotations={"org.opencontainers.image.title": payload_name}
            )
        )
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "config": blob(b"{}", config_kind),
            "layers": layers,
            "annotations": release.labels("1.2.3", REVISION),
        }
    ).encode()
    descriptor = blob(
        manifest,
        "application/vnd.oci.image.manifest.v1+json",
        annotations={"org.opencontainers.image.ref.name": "1.2.3"},
    )
    release.write_json(blobs.parent.parent / "index.json", {"manifests": [descriptor]})
    return {
        "name": name,
        "repository": repository,
        "tagReference": f"{repository}:1.2.3",
        "manifestDigest": release.digest_bytes(manifest),
        "mediaType": config_kind,
        "payloads": [
            {
                "filename": layer["annotations"]["org.opencontainers.image.title"],
                "digest": layer["digest"],
                "mediaType": layer["mediaType"],
            }
            for layer in layers
        ],
    }


def test_incomplete_or_mixed_version_candidate_is_rejected(candidate):
    original = release.candidate(candidate)
    for mutate in (
        lambda value: value["artifacts"].pop(),
        lambda value: value["artifacts"][0].update(tagReference="ghcr.io/other/module:1.2.2"),
        lambda value: value.update(runtimeValidated=True),
    ):
        changed = copy.deepcopy(original)
        mutate(changed)
        release.write_json(candidate / "release.json", changed)
        with pytest.raises(ValueError):
            release.candidate(candidate)


def test_changed_local_oci_blob_fails_before_any_registry_write(candidate):
    ledger = release.candidate(candidate)
    item = ledger["artifacts"][0]
    path = candidate / "layouts" / item["name"] / "blobs/sha256" / item["payloads"][0]["digest"][7:]
    path.write_bytes(b"modified")
    with (
        patch.object(release, "remote_manifest") as remote,
        pytest.raises(ValueError, match="blob"),
    ):
        release.publish(candidate, "1.2.3", REVISION)
    remote.assert_not_called()


def test_conflict_in_last_artifact_prevents_all_publication(candidate):
    ledger = release.candidate(candidate)
    conflict = ledger["images"][-1]

    def existing(reference, **_kwargs):
        if reference == conflict["tagReference"]:
            return json.dumps({"config": {"digest": "sha256:" + "b" * 64}, "layers": [{}]}).encode()
        return None

    with (
        patch.object(release, "remote_manifest", side_effect=existing),
        patch.object(release, "run") as command,
        pytest.raises(ValueError, match="Immutable image tag conflict"),
    ):
        release.publish(candidate, "1.2.3", REVISION)
    command.assert_not_called()


def test_dirty_candidate_cannot_be_published(candidate):
    ledger = release.candidate(candidate)
    ledger["sourceDirty"] = True
    release.write_json(candidate / "release.json", ledger)
    with (
        patch.object(release, "remote_manifest") as remote,
        pytest.raises(ValueError, match="clean"),
    ):
        release.publish(candidate, "1.2.3", REVISION)
    remote.assert_not_called()


def test_failed_anonymous_verification_removes_success_marker(candidate):
    (candidate / "verification.json").write_text('{"anonymousFullPullVerified": true}')
    with (
        patch.object(release, "remote_manifest", side_effect=ValueError("401 Unauthorized")),
        pytest.raises(ValueError, match="401"),
    ):
        release.verify(candidate)
    assert not (candidate / "verification.json").exists()


@pytest.mark.parametrize("failure", [None, "modified-image-layer", "unavailable-last-layer"])
def test_anonymous_full_verification_without_build_outputs(candidate, tmp_path, failure):
    ledger = release.candidate(candidate)
    manifests = {}
    blobs = {}
    for item in ledger["artifacts"]:
        directory = candidate / "layouts" / item["name"] / "blobs/sha256"
        manifests[item["tagReference"]] = (
            directory / item["manifestDigest"].removeprefix("sha256:")
        ).read_bytes()
        for blob in directory.iterdir():
            blobs[f"{item['repository']}@sha256:{blob.name}"] = blob.read_bytes()
    for item in ledger["images"]:
        with tarfile.open(candidate / "images" / f"{item['name']}.tar") as archive:
            config = archive.extractfile("config.json").read()
            layer = archive.extractfile("layer.tar").read()
        if failure == "modified-image-layer" and item["name"] == "simulator":
            layer = b"changed-after-testing"
        layer = gzip.compress(layer, mtime=0)
        descriptors = []
        for data, media_type in (
            (config, "application/vnd.docker.container.image.v1+json"),
            (layer, "application/vnd.docker.image.rootfs.diff.tar.gzip"),
        ):
            digest = release.digest_bytes(data)
            blobs[f"{item['repository']}@{digest}"] = data
            descriptors.append({"digest": digest, "mediaType": media_type, "size": len(data)})
        manifests[item["tagReference"]] = json.dumps(
            {"schemaVersion": 2, "config": descriptors[0], "layers": descriptors[1:]}
        ).encode()
        if failure == "unavailable-last-layer" and item["name"] == "simulator":
            del blobs[f"{item['repository']}@{descriptors[1]['digest']}"]

    def manifest(reference, *, auth):
        assert json.loads(auth.read_text()) == {"auths": {}}
        return manifests[reference]

    def fetch_blob(*arguments):
        assert arguments[:3] == ("oras", "blob", "fetch")
        assert arguments[3] == "--registry-config"
        assert json.loads(Path(arguments[4]).read_text()) == {"auths": {}}
        reference = arguments[5]
        if reference not in blobs:
            raise ValueError("registry blob unavailable")
        assert arguments[6] == "--output"
        Path(arguments[7]).write_bytes(blobs[reference])
        return b""

    directory = tmp_path / "downloaded"
    directory.mkdir()
    (directory / "release.json").write_bytes((candidate / "release.json").read_bytes())
    marker = directory / "verification.json"
    marker.write_text('{"anonymousFullPullVerified": true}')
    with (
        patch.object(release, "remote_manifest", side_effect=manifest) as remote,
        patch.object(release, "run", side_effect=fetch_blob),
    ):
        if failure:
            expected = (
                "tested root filesystem" if failure == "modified-image-layer" else "unavailable"
            )
            with pytest.raises(ValueError, match=expected):
                release.verify(directory, published=True)
            assert not marker.exists()
        else:
            release.verify(directory, published=True)
            result = json.loads(marker.read_text())
            assert result["anonymousFullPullVerified"] is True
            assert result["runtimeValidated"] is False
            assert {item["tagReference"] for item in result["artifacts"]} == set(manifests)
            assert remote.call_count == len(manifests)
            for item in result["artifacts"]:
                assert item["manifestDigest"] == release.digest_bytes(
                    manifests[item["tagReference"]]
                )
