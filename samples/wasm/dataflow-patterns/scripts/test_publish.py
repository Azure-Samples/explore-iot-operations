#!/usr/bin/env python3
"""Exercise real local OCI packaging without credentials or network publishing."""
import json
import hashlib
import os
import runpy
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parent
PREPARE = runpy.run_path(str(SCRIPTS / "prepare-release.py"))
ARTIFACT_NAMES = set(PREPARE["MODULES"].values()) | set(PREPARE["GRAPHS"]) | {"dataflow-patterns"}


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
            chart.update(version="1.0.0-rc.1", appVersion="1.0.0-rc.1")
            chart["annotations"]["org.opencontainers.image.revision"] = "a" * 40
            chart_path.write_text(yaml.safe_dump(chart))
            values_path = work / "chart" / "values.yaml"
            values = yaml.safe_load(values_path.read_text())
            values["artifactVersion"] = "1.0.0-rc.1"
            values.setdefault("ticker", {}).setdefault("image", {}).update(
                repository=PREPARE["TICKER_REPOSITORY"], tag="1.0.0-rc.1")
            values_path.write_text(yaml.safe_dump(values))
            (work / "release.json").write_text(json.dumps({
                "version": "1.0.0-rc.1", "revision": "a" * 40, "dependencies": [],
            }))
            # Minimal component header; this test validates packaging, NOT WASM execution.
            (artifacts / "module_dataflow_patterns.wasm").write_bytes(b"\0asm\x0d\0\x01\0")
            (artifacts / "module_dataflow_pattern_filter.wasm").write_bytes(b"\0asm\x0d\0\x01\0filter")
            for name in PREPARE["GRAPHS"]:
                (artifacts / f"{name}.yaml").write_text(yaml.safe_dump({
                    "metadata": {"version": "1.0.0-rc.1"},
                    "operations": [
                        {"operationType": kind,
                         "module": f"azure-samples/explore-iot-operations/dataflow-patterns/{module}:1.0.0-rc.1"}
                        for kind, module in (("map", "module-dataflow-patterns"),
                                             ("filter", "module-dataflow-pattern-filter"))
                    ],
                }))
            env = dict(os.environ, SOURCE_DATE_EPOCH="1760000000")
            command = ["bash", str(SCRIPTS / "publish.sh"), str(work), "--stage-only"]
            subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
            first = (work / "artifacts.tsv").read_text()
            subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(first, (work / "artifacts.tsv").read_text())
            entries = [line.split("\t") for line in first.splitlines()]
            self.assertEqual(len(entries), len(ARTIFACT_NAMES))
            self.assertEqual({entry[0] for entry in entries}, ARTIFACT_NAMES)
            ledger = json.loads((work / "artifacts.json").read_text())
            self.assertEqual(ledger["revision"], "a" * 40)
            self.assertFalse(ledger["runtimeVerified"])
            self.assertEqual(ledger["dependencies"], [])
            self.assertFalse((work / "verification.json").exists())
            self.assertEqual(len(ledger["artifacts"]), len(ARTIFACT_NAMES))
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
                if name.startswith("module-"):
                    self.assertEqual(manifest["config"]["mediaType"],
                                     "application/vnd.module.wasm.content.layer.v1+wasm")
                    self.assertEqual(manifest["layers"][0]["mediaType"], "application/wasm")
                    self.assertEqual(manifest["layers"][0]["annotations"]["org.opencontainers.image.title"],
                                     f"{name}.wasm")
                elif name in PREPARE["GRAPHS"]:
                    self.assertEqual(manifest["config"]["mediaType"],
                                     "application/vnd.microsoft.aio.graph.v1+yaml")
                    self.assertEqual(manifest["layers"][0]["mediaType"], "application/yaml")
                    self.assertEqual(manifest["layers"][0]["annotations"]["org.opencontainers.image.title"],
                                     f"{name}.yaml")
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
                "    mode = os.environ['REMOTE_MODE']\n"
                "    conflict = mode == 'conflict' or (mode == 'filter-conflict' and\n"
                "        args[2].endswith('/module-dataflow-pattern-filter:1.0.0-rc.1')) or (\n"
                "        mode == 'late-conflict' and '/helm/dataflow-patterns:' in args[2])\n"
                "    if conflict:\n"
                "        print(json.dumps({'digest': 'sha256:' + '0' * 64}))\n"
                "        sys.exit(0)\n"
                "    if mode in ('filter-conflict', 'late-conflict'):\n"
                "        print('Error: MANIFEST_UNKNOWN', file=sys.stderr)\n"
                "        sys.exit(1)\n"
                "    print('Error: unauthorized: access denied', file=sys.stderr)\n"
                "    sys.exit(1)\n"
                "open(os.environ['UPLOAD_MARKER'], 'w').write('unexpected remote operation')\n"
                "sys.exit(99)\n"
            )
            mock.chmod(0o755)
            for mode in ("conflict", "filter-conflict", "late-conflict", "unauthorized"):
                marker = work / f"unexpected-{mode}"
                mocked_env = dict(env, PATH=f"{mock_bin}:{os.environ['PATH']}",
                                  REAL_ORAS=shutil.which("oras"), REMOTE_MODE=mode,
                                  UPLOAD_MARKER=str(marker))
                result = subprocess.run(command[:-1], env=mocked_env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(marker.exists(), result.stdout + result.stderr)
                expected = "unauthorized" if mode == "unauthorized" else "immutable tag conflict"
                self.assertIn(expected, result.stderr)
            # Serve all remote reads from real local layouts. Successful retries
            # must not upload and must anonymously fetch both modules in full.
            mock.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, subprocess, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "if '--oci-layout' in args:\n"
                "    sys.exit(subprocess.call([os.environ['REAL_ORAS']] + args))\n"
                "assert args[:2] in (['manifest', 'fetch'], ['blob', 'fetch']) or args[0] == 'pull', args\n"
                "anonymous = '--registry-config' in args\n"
                "if anonymous:\n"
                "    index = args.index('--registry-config')\n"
                "    auth = Path(args[index + 1])\n"
                "    assert json.loads(auth.read_text()) == {'auths': {}}\n"
                "    del args[index:index + 2]\n"
                "else:\n"
                "    assert args[:2] == ['manifest', 'fetch'] and '--descriptor' in args\n"
                "index = 1 if args[0] == 'pull' else 2\n"
                "reference = args[index]\n"
                "name = reference.rsplit('/', 1)[1].split('@')[0].split(':')[0]\n"
                "suffix = '@' + reference.split('@')[1] if '@' in reference else ':' + reference.rsplit(':', 1)[1]\n"
                "args[index] = str(Path(os.environ['RELEASE_ROOT']) / 'layouts' / name) + suffix\n"
                "args.insert(index, '--oci-layout')\n"
                "if anonymous:\n"
                "    with open(os.environ['PULL_LOG'], 'a') as log:\n"
                "        log.write(json.dumps([name, args[:index]]) + '\\n')\n"
                "sys.exit(subprocess.call([os.environ['REAL_ORAS']] + args))\n"
            )
            helm_mock = mock_bin / "helm"
            helm_mock.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, shutil, subprocess, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "if args[0] != 'pull':\n"
                "    sys.exit(subprocess.call([os.environ['REAL_HELM']] + args))\n"
                "assert json.loads(Path(os.environ['HELM_REGISTRY_CONFIG']).read_text()) == {'auths': {}}\n"
                "assert json.loads((Path(os.environ['DOCKER_CONFIG']) / 'config.json').read_text()) == {'auths': {}}\n"
                "version = args[args.index('--version') + 1]\n"
                "destination = Path(args[args.index('--destination') + 1])\n"
                "shutil.copyfile(Path(os.environ['RELEASE_ROOT']) / 'artifacts' / f'dataflow-patterns-{version}.tgz',\n"
                "                destination / f'dataflow-patterns-{version}.tgz')\n"
            )
            helm_mock.chmod(0o755)
            pull_log = work / "pulls.jsonl"
            mocked_env = dict(env, PATH=f"{mock_bin}:{os.environ['PATH']}",
                              REAL_ORAS=shutil.which("oras"), REAL_HELM=shutil.which("helm"),
                              RELEASE_ROOT=str(work), PULL_LOG=str(pull_log))
            result = subprocess.run(command[:-1], env=mocked_env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            verified = json.loads((work / "verification.json").read_text())
            self.assertEqual(len(verified["artifacts"]), len(ARTIFACT_NAMES))
            self.assertTrue(verified["anonymousFullPullsVerified"])
            self.assertTrue(verified["packagedChartVerified"])
            self.assertFalse(verified["runtimeVerified"])
            pulls = [json.loads(line) for line in pull_log.read_text().splitlines()]
            for operation in (["manifest", "fetch"], ["blob", "fetch"], ["pull"]):
                self.assertEqual({name for name, args in pulls if args == operation},
                                 {entry[0] for entry in entries})
            for name, _repository, _digest, filename in entries:
                self.assertEqual((work / "anonymous" / name / filename).read_bytes(),
                                 (artifacts / filename).read_bytes())
            # A forged/incomplete ledger must fail before any registry reads.
            tsv_path = work / "artifacts.tsv"
            original_tsv = tsv_path.read_text()
            for invalid_tsv in (
                "\n".join(original_tsv.splitlines()[:-1]) + "\n",
                original_tsv.replace("ghcr.io/azure-samples/", "ghcr.io/foreign-owner/"),
                original_tsv.replace("module-dataflow-pattern-filter\t",
                                     "module-dataflow-patterns\t", 1),
                "\n".join(line for line in original_tsv.splitlines()
                          if not line.startswith("graph-smooth-readings\t")) + "\n",
            ):
                tsv_path.write_text(invalid_tsv)
                before = pull_log.read_bytes()
                result = subprocess.run(["bash", str(SCRIPTS / "verify-published.sh"), str(work)],
                                        env=mocked_env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((work / "verification.json").exists())
                self.assertEqual(pull_log.read_bytes(), before)
            tsv_path.write_text(original_tsv)
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
                [graph["operations"][0], {
                    "operationType": "filter",
                    "module": graph["operations"][0]["module"],
                }],
                [{
                    "operationType": "map",
                    "module": graph["operations"][1]["module"],
                }, graph["operations"][1]],
            ):
                graph_path.write_text(yaml.safe_dump(dict(graph, operations=invalid)))
                result = subprocess.run(command, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ValueError", result.stderr)
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
