"""Exercise the ticker publisher without registry writes or Docker dependencies."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid


SCRIPTS = Path(__file__).resolve().parent
CODE = (SCRIPTS / "publish-ticker.sh").read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
REPOSITORY = "ghcr.io/azure-samples/explore-iot-operations/dataflow-pattern-ticker"
SOURCE = "https://github.com/Azure-Samples/explore-iot-operations"


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


class TickerReleaseTests(unittest.TestCase):
    def setUp(self):
        self.root = SCRIPTS / ".work" / ("ticker-test-" + uuid.uuid4().hex)
        self.root.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.root)
        self.version, self.revision = "1.0.0-rc.3", "a" * 40
        self.reference = f"{REPOSITORY}:{self.version}"
        (self.root / "release.json").write_text(json.dumps({
            "version": self.version, "revision": self.revision,
        }))
        self.config = json.dumps({"config": {"Labels": {
            "org.opencontainers.image.source": SOURCE,
            "org.opencontainers.image.revision": self.revision,
            "org.opencontainers.image.version": self.version,
            "org.opencontainers.image.url": f"{SOURCE}/tree/{self.revision}",
        }}, "rootfs": {"type": "layers", "diff_ids": [digest(b"layer")]}}).encode()
        self.layer = b"layer"
        self.config_digest = digest(self.config)
        self.manifest = {
            "schemaVersion": 2,
            "config": {"digest": self.config_digest, "size": len(self.config)},
            "layers": [{"digest": digest(self.layer), "size": len(self.layer)}],
        }
        self.save()
        self.mode = "existing"
        self.calls = []
        self.corrupt = False
        self.bad_loaded = False
        self.containerd = False

    def save(self):
        with tarfile.open(self.root / "ticker-image.tar", "w") as archive:
            for name, content in {
                "manifest.json": json.dumps([{
                    "RepoTags": [self.reference], "Config": "config.json",
                    "Layers": ["layer.tar"],
                }]).encode(),
                "config.json": self.config, "layer.tar": self.layer,
            }.items():
                member = tarfile.TarInfo(name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        output, error, status = b"", b"", 0
        if args[:3] == ("docker", "image", "inspect"):
            item = {"Id": "sha256:bad" if self.bad_loaded else self.config_digest}
            if self.containerd:
                item = {"Id": "sha256:manifest", "Descriptor": {
                    "annotations": {"config.digest": self.config_digest},
                }}
            output = json.dumps([item]).encode()
        elif args[:3] == ["oras", "manifest", "fetch"] or args[:3] == ("oras", "manifest", "fetch"):
            if "--registry-config" not in args and self.mode in {"absent", "oras-absent", "auth", "network", "404"}:
                error = {
                    "absent": b"MANIFEST_UNKNOWN", "auth": b"unauthorized",
                    "network": b"connection refused",
                    "404": b"proxy HTTP 404 not found",
                    "oras-absent": (
                        f'Error response from registry: failed to fetch the content of "{self.reference}": '
                        f'{self.reference}: not found\n'
                    ).encode(),
                }[self.mode]
                status = 1
                if self.mode in {"absent", "oras-absent"}:
                    self.mode = "existing"
            else:
                output = json.dumps(self.manifest).encode()
        elif args[:3] == ("oras", "blob", "fetch"):
            blob_reference = args[5]
            content = self.config if blob_reference.endswith(self.config_digest) else self.layer
            if self.corrupt and content == self.layer:
                content = b"wrong"
            Path(args[-1]).write_bytes(content)
        if status and kwargs.get("check"):
            raise subprocess.CalledProcessError(status, args, output, error)
        return SimpleNamespace(stdout=output, stderr=error, returncode=status)

    def publish(self):
        with patch.object(sys, "argv", ["publish-ticker.sh", str(self.root)]), \
                patch.dict(os.environ, {
                    "RELEASE_VERSION": self.version, "GITHUB_SHA": self.revision,
                }), patch("subprocess.run", side_effect=self.fake_run):
            exec(compile(CODE, "publish-ticker.sh:python", "exec"), {})

    def pushed(self):
        return any(args[:2] == ("docker", "push") for args in self.calls)

    def test_absent_tag_pushes_saved_image_and_verifies_every_blob(self):
        self.mode = "absent"
        self.publish()
        self.assertTrue(self.pushed())
        marker = json.loads((self.root / "ticker-image-verification.json").read_text())
        self.assertTrue(marker["anonymousFullPullVerified"])
        self.assertFalse(marker["runtimeVerified"])
        self.assertEqual(marker["layersVerified"], 1)
        blobs = [args for args in self.calls if args[:3] == ("oras", "blob", "fetch")]
        self.assertEqual(len(blobs), 2)
        self.assertTrue(all("--registry-config" in args for args in blobs))

    def test_existing_exact_config_is_verify_only(self):
        self.publish()
        self.assertFalse(self.pushed())

    def test_oras_ghcr_missing_tag_format_is_absence(self):
        self.mode = "oras-absent"
        self.publish()
        self.assertTrue(self.pushed())

    def test_containerd_manifest_id_uses_config_annotation(self):
        self.containerd = True
        self.publish()
        self.assertFalse(self.pushed())

    def test_conflicting_config_refuses_overwrite(self):
        self.manifest["config"]["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(SystemExit, "conflict"):
            self.publish()
        self.assertFalse(self.pushed())

    def test_auth_and_network_errors_are_not_absence(self):
        for mode in ("auth", "network", "404"):
            with self.subTest(mode=mode):
                self.mode = mode
                with self.assertRaisesRegex(SystemExit, "absence"):
                    self.publish()
                self.assertFalse(self.pushed())

    def test_corrupt_layer_removes_stale_verification(self):
        (self.root / "ticker-image-verification.json").write_text("{}")
        self.corrupt = True
        with self.assertRaisesRegex(SystemExit, "digest/size"):
            self.publish()
        self.assertFalse((self.root / "ticker-image-verification.json").exists())

    def test_wrong_labels_fail_before_load_or_push(self):
        self.config = self.config.replace(self.revision.encode(), b"b" * 40)
        self.save()
        with self.assertRaisesRegex(SystemExit, "labels"):
            self.publish()
        self.assertEqual(self.calls, [])

    def test_loaded_image_must_match_saved_config(self):
        self.bad_loaded = True
        with self.assertRaisesRegex(SystemExit, "Loaded image"):
            self.publish()
        self.assertFalse(self.pushed())


if __name__ == "__main__":
    unittest.main()
