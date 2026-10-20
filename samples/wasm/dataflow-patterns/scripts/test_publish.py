#!/usr/bin/env python3
"""Exercise real local OCI packaging without credentials or network publishing."""
import json
import hashlib
import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parent


class PublishTests(unittest.TestCase):
    def test_local_oci_packages_are_reproducible(self):
        self.assertIsNotNone(shutil.which("oras"), "ORAS is required for offline OCI packaging checks")
        work = SCRIPTS / ".work" / f"publish-test-{uuid.uuid4().hex}"
        artifacts = work / "artifacts"
        artifacts.mkdir(parents=True)
        try:
            shutil.copytree(SCRIPTS.parent / "chart", work / "chart")
            chart_path = work / "chart" / "Chart.yaml"
            chart = yaml.safe_load(chart_path.read_text())
            chart["annotations"]["org.opencontainers.image.revision"] = "a" * 40
            chart_path.write_text(yaml.safe_dump(chart))
            (work / "release.json").write_text(json.dumps({
                "version": "1.0.0-rc.1", "revision": "a" * 40, "dependencies": [],
            }))
            # Minimal component header; this test validates packaging, NOT WASM execution.
            (artifacts / "module_dataflow_patterns.wasm").write_bytes(b"\0asm\x0d\0\x01\0")
            for name in ("graph-align-by-time", "graph-correlate-by-id", "graph-versioned-predictor"):
                (artifacts / f"{name}.yaml").write_text(yaml.safe_dump({
                    "metadata": {"version": "1.0.0-rc.1"},
                    "operations": [
                        {"operationType": kind,
                         "module": "azure-samples/explore-iot-operations/dataflow-patterns/module-dataflow-patterns:1.0.0-rc.1"}
                        for kind in ("map", "filter")
                    ],
                }))
            env = dict(os.environ, SOURCE_DATE_EPOCH="1760000000")
            command = ["bash", str(SCRIPTS / "publish.sh"), str(work), "--stage-only"]
            subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
            first = (work / "artifacts.tsv").read_text()
            subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(first, (work / "artifacts.tsv").read_text())
            entries = [line.split("\t") for line in first.splitlines()]
            self.assertEqual(len(entries), 5)
            ledger = json.loads((work / "artifacts.json").read_text())
            self.assertEqual(ledger["revision"], "a" * 40)
            self.assertFalse(ledger["runtimeVerified"])
            self.assertEqual(ledger["dependencies"], [])
            self.assertFalse((work / "verification.json").exists())
            self.assertEqual(len(ledger["artifacts"]), 5)
            for name, repository, digest, filename in entries:
                entry = next(item for item in ledger["artifacts"] if item["name"] == name)
                self.assertEqual(entry["tagReference"], f"{repository}:1.0.0-rc.1")
                self.assertEqual(entry["digestReference"], f"{repository}@{digest}")
                self.assertEqual(entry["payloadDigest"],
                                 "sha256:" + hashlib.sha256((artifacts / filename).read_bytes()).hexdigest())
                raw = subprocess.check_output([
                    "oras", "manifest", "fetch", "--oci-layout", f"{work}/layouts/{name}:1.0.0-rc.1",
                ])
                manifest = json.loads(raw)
                self.assertEqual(f"sha256:{hashlib.sha256(raw).hexdigest()}", digest)
                self.assertEqual(manifest["annotations"]["org.opencontainers.image.revision"], "a" * 40)
                self.assertEqual(manifest["annotations"]["org.opencontainers.image.version"], "1.0.0-rc.1")
                self.assertEqual(len(manifest["layers"]), 1)
                self.assertRegex(digest, "^sha256:[0-9a-f]{64}$")
            helm_manifest = json.loads(subprocess.check_output([
                "oras", "manifest", "fetch", "--oci-layout", f"{work}/layouts/dataflow-patterns:1.0.0-rc.1",
            ]))
            self.assertEqual(helm_manifest["config"]["mediaType"], "application/vnd.cncf.helm.config.v1+json")
            # Remote fetch failures/conflicts must never reach an upload, even
            # though the local OCI preparation uses the real ORAS executable.
            mock_bin = work / "mock-bin"
            mock_bin.mkdir()
            mock = mock_bin / "oras"
            mock.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, subprocess, sys\n"
                "args = sys.argv[1:]\n"
                "if '--oci-layout' in args:\n"
                "    sys.exit(subprocess.call([os.environ['REAL_ORAS']] + args))\n"
                "if args[:2] == ['manifest', 'fetch']:\n"
                "    if os.environ['REMOTE_MODE'] == 'conflict':\n"
                "        print(json.dumps({'digest': 'sha256:' + '0' * 64}))\n"
                "        sys.exit(0)\n"
                "    print('Error: unauthorized: access denied', file=sys.stderr)\n"
                "    sys.exit(1)\n"
                "open(os.environ['UPLOAD_MARKER'], 'w').write('unexpected remote operation')\n"
                "sys.exit(99)\n"
            )
            mock.chmod(0o755)
            for mode in ("conflict", "unauthorized"):
                marker = work / f"unexpected-{mode}"
                mocked_env = dict(env, PATH=f"{mock_bin}:{os.environ['PATH']}",
                                  REAL_ORAS=shutil.which("oras"), REMOTE_MODE=mode,
                                  UPLOAD_MARKER=str(marker))
                result = subprocess.run(command[:-1], env=mocked_env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists(), result.stdout + result.stderr)
                expected = "immutable tag conflict" if mode == "conflict" else "unauthorized"
                self.assertIn(expected, result.stderr)
            graph_path = artifacts / "graph-align-by-time.yaml"
            graph = yaml.safe_load(graph_path.read_text())
            for invalid in (
                graph["operations"][:1],
                [graph["operations"][0], {
                    "operationType": "filter",
                    "module": "mcr.microsoft.com/azureiotoperations/module-dataflow-filter:1.0.0",
                }],
                [graph["operations"][0], {
                    "operationType": "filter",
                    "module": graph["operations"][1]["module"].replace("rc.1", "rc.2"),
                }],
            ):
                graph_path.write_text(yaml.safe_dump(dict(graph, operations=invalid)))
                result = subprocess.run(command, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ValueError", result.stderr)
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
