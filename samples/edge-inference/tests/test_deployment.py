import base64
import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml
from PIL import Image

import render

SOURCE = Path(__file__).resolve().parents[1]
COMMAND_STUB = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["EDGE_TEST_COMMAND_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\\n")
if tool == "az" and args[0] == "rest":
    print(Path(os.environ["EDGE_TEST_GRAPHS"]).read_text())
elif tool == "az" and args[:2] == ["resource", "update"]:
    pass
elif tool == "kubectl" and "get" in args:
    print(json.dumps({"status": {
        "streams": [{"name": "camera-snapshots", "error": None}],
        "managementGroups": [{"actions": [{"name": "ExtractClip", "error": None}]}]
    }}))
elif tool == "kubectl" and ("wait" in args or "rollout" in args):
    pass
else:
    raise SystemExit("Unexpected external command: " + tool + " " + " ".join(args))
"""


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sample = self.root / "sample"
        self.sample.mkdir()
        for filename in (
            "config.schema.json",
            "config.example.json",
            "scenarios.json",
            "render.py",
            "inspection.py",
            "deploy.sh",
        ):
            shutil.copyfile(SOURCE / filename, self.sample / filename)
        shutil.copytree(SOURCE / "kubernetes", self.sample / "kubernetes")
        (self.sample / "models").mkdir()
        shutil.copyfile(SOURCE / "models/catalog.json", self.sample / "models/catalog.json")
        self.patch_root = patch.object(render, "ROOT", self.sample)
        self.patch_root.start()
        self.addCleanup(self.patch_root.stop)
        self.models = self.sample / ".assets/models"
        self.output = self.sample / ".generated"
        self.config = json.loads((SOURCE / "config.example.json").read_text())
        self.config.update(
            subscriptionId="12345678-1234-1234-1234-123456789abc",
            resourceGroup="rg-edge-test",
            aioInstanceName="aio-test",
            customLocationName="custom-location",
            kubeContext="test-context",
            foundryTrustSecret="foundry-ca",
            modelRegistry="example.azurecr.io",
            modelRegistrySecret="model-registry",
            collectorImage="example.azurecr.io/samples/edge-inference:sample-v1",
            imagePullSecret="observer-pull",
            graphRegistryEndpointName="preview-graphs",
        )

    def prepare_metadata(self):
        catalog = json.loads((self.sample / "models/catalog.json").read_text())
        for name, metadata in catalog.items():
            package = self.models / name / "package"
            package.mkdir(parents=True, exist_ok=True)
            labels = metadata.get("id2label", {"0": "person", "56": "chair"})
            model_bytes = b"rendering-test model fixture; not an inference model"
            label_bytes = json.dumps({"id2label": labels}).encode()
            (package / "model.onnx").write_bytes(model_bytes)
            (package / "config.json").write_bytes(label_bytes)
            (package / "provenance.json").write_text(
                json.dumps(
                    {
                        **metadata,
                        "outputTensorKey": "detections_0",
                        "packagedModelSha256": hashlib.sha256(model_bytes).hexdigest(),
                        "packagedConfigSha256": hashlib.sha256(label_bytes).hexdigest(),
                    }
                )
            )

    def test_authenticated_camera_and_model_metadata_survive_rendering(self):
        self.prepare_metadata()
        authentication = {
            "method": "UsernamePassword",
            "usernamePasswordCredentials": {
                "usernameSecretName": "camera-user",
                "passwordSecretName": "camera-password",
            },
        }
        self.config["cameras"]["equipment-area"] = {
            "address": "rtsps://camera.example.com:322/stream",
            "authentication": authentication,
        }
        render.render(self.config, self.output, models=self.models)
        camera, asset = yaml.safe_load_all((self.output / "camera-equipment-area.yaml").read_text())
        self.assertEqual(
            camera["spec"]["endpoints"]["inbound"]["rtsp"]["authentication"], authentication
        )
        self.assertEqual(asset["spec"]["deviceRef"]["deviceName"], camera["metadata"]["name"])
        for path in self.output.glob("*.yaml"):
            with self.subTest(manifest=path.name):
                self.assertTrue(
                    all(isinstance(item, dict) for item in yaml.safe_load_all(path.read_text()))
                )
        scenarios = json.loads((self.output / "scenarios.json").read_text())
        config_map = json.loads((self.output / "scenarios-configmap.json").read_text())
        self.assertEqual(json.loads(config_map["data"]["scenarios.json"]), scenarios)
        for template in ("connector", "dataflows"):
            parameters = json.loads((self.output / f"{template}.parameters.json").read_text())[
                "parameters"
            ]
            self.assertEqual(parameters["scenarios"]["value"], scenarios)
        model = yaml.safe_load((self.output / "model-equipment-area.yaml").read_text())
        self.assertEqual(model["metadata"]["name"], scenarios[1]["modelName"])
        self.assertEqual(model["metadata"]["namespace"], self.config["foundryNamespace"])

    def test_invalid_configuration_is_rejected_without_model_files(self):
        mutations = (
            lambda config: config.update(enabledScenarios="equipment-area"),
            lambda config: config.update(stateClaimName=config["dataClaimName"]),
            lambda config: config["cameras"].pop("pcb-quality"),
            lambda config: config.update(collectorImage="example.azurecr.io/observer"),
            lambda config: config.update(modelTag="latest"),
            lambda config: config["cameras"]["equipment-area"].update(
                address="rtsp://camera:70000/stream"
            ),
            lambda config: config["graphs"].update(inference="graphs/inference:0.2.0-preview.0"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                config = copy.deepcopy(self.config)
                mutate(config)
                with self.assertRaises(ValueError):
                    render.validate_config(config)
        self.assertFalse(self.models.exists())
        self.assertFalse(self.output.exists())

    def test_camera_validation_does_not_echo_credentials(self):
        for camera in (
            {
                "address": "rtsp://user:do-not-log-this@camera/stream",
                "authentication": {"method": "Anonymous"},
            },
            {
                "address": "rtsp://camera/stream",
                "authentication": {
                    "method": "UsernamePassword",
                    "password": "do-not-log-this",
                },
            },
        ):
            with self.subTest(camera=camera):
                config = copy.deepcopy(self.config)
                config["cameras"]["equipment-area"] = camera
                with self.assertRaises(ValueError) as failure:
                    render.validate_config(config)
                self.assertNotIn("do-not-log-this", str(failure.exception))

    def test_modified_package_or_missing_replay_leaves_output_unchanged(self):
        for filename in ("model.onnx", "config.json"):
            with self.subTest(filename=filename):
                self.prepare_metadata()
                render.render(self.config, self.output, models=self.models)
                existing = {path.name: path.read_bytes() for path in self.output.iterdir()}
                path = self.models / "equipment-area/package" / filename
                path.write_bytes(path.read_bytes() + b"\n")
                with self.assertRaisesRegex(ValueError, "changed"):
                    render.render(self.config, self.output, models=self.models)
                self.assertEqual(
                    {path.name: path.read_bytes() for path in self.output.iterdir()},
                    existing,
                )
        self.prepare_metadata()
        with self.assertRaises(FileNotFoundError):
            render.render(self.config, self.output, replay=True, models=self.models)
        self.assertEqual({path.name: path.read_bytes() for path in self.output.iterdir()}, existing)

    def test_changed_replay_image_rolls_out_a_new_publisher(self):
        self.prepare_metadata()
        self.config["enabledScenarios"] = ["equipment-area"]
        directory = self.sample / ".assets/replay"
        directory.mkdir(parents=True)
        image = directory / "equipment-area.jpg"
        hashes = []
        for color in ("black", "white"):
            Image.new("RGB", (640, 640), color).save(image, "JPEG")
            render.render(self.config, self.output, replay=True, models=self.models)
            config_map, deployment, _ = yaml.safe_load_all(
                (self.output / "replay-equipment-area.yaml").read_text()
            )
            self.assertEqual(
                base64.b64decode(config_map["binaryData"]["camera.jpg"]), image.read_bytes()
            )
            hashes.append(
                deployment["spec"]["template"]["metadata"]["annotations"][
                    "edge-inference/config-hash"
                ]
            )
        self.assertNotEqual(hashes[0], hashes[1])

    def run_mode(self, action, graphs, next_link=None):
        bin_directory = self.root / "bin"
        bin_directory.mkdir(exist_ok=True)
        for name in ("az", "kubectl"):
            executable = bin_directory / name
            executable.write_text(COMMAND_STUB)
            executable.chmod(0o755)
        configuration = self.root / "configuration.json"
        configuration.write_text(json.dumps(self.config))
        graph_fixture = self.root / "graphs.json"
        graph_fixture.write_text(
            json.dumps(
                {
                    "value": [{"name": name} for name in graphs],
                    "nextLink": next_link,
                }
            )
        )
        command_log = self.root / "commands.jsonl"
        command_log.write_text("")
        environment = {
            **os.environ,
            "PATH": f"{bin_directory}:{Path(sys.executable).parent}:{os.environ['PATH']}",
            "EDGE_TEST_COMMAND_LOG": str(command_log),
            "EDGE_TEST_GRAPHS": str(graph_fixture),
        }
        result = subprocess.run(
            ["bash", str(self.sample / "deploy.sh"), action, str(configuration)],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        calls = [json.loads(line) for line in command_log.read_text().splitlines()]
        updates = [call["args"] for call in calls if call["args"][:2] == ["resource", "update"]]
        return result, calls, updates

    def test_disable_covers_retired_scenarios_without_models_or_kubernetes_access(self):
        self.config["enabledScenarios"] = ["equipment-area"]
        graphs = [
            f"aio-test/edge-inference/{scenario}-{stage}"
            for scenario in ("pcb-quality", "equipment-area")
            for stage in ("capture", "inference", "postprocessing")
        ]
        result, calls, updates = self.run_mode("disable", graphs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(updates), 6)
        self.assertTrue(all(call["tool"] == "az" for call in calls))
        for arguments in updates:
            self.assertIn("properties.mode=Disabled", arguments)
            self.assertEqual(arguments[arguments.index("--include-response-body") + 1], "true")
        self.assertTrue(updates[0][updates[0].index("--ids") + 1].endswith("-capture"))
        self.assertFalse(self.models.exists())
        self.assertFalse(self.output.exists())

    def test_enable_targets_selected_graphs_downstream_first(self):
        self.config["enabledScenarios"] = ["equipment-area"]
        graphs = [
            f"{scenario}-{stage}"
            for scenario in ("pcb-quality", "equipment-area")
            for stage in ("capture", "inference", "postprocessing")
        ]
        result, _, updates = self.run_mode("enable", graphs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [arguments[arguments.index("--ids") + 1].split("/")[-1] for arguments in updates],
            ["equipment-area-postprocessing", "equipment-area-inference", "equipment-area-capture"],
        )
        self.assertTrue(all("properties.mode=Enabled" in arguments for arguments in updates))
        self.assertFalse(self.models.exists())
        self.assertFalse(self.output.exists())

    def test_unfamiliar_or_incomplete_profiles_are_not_modified(self):
        for action, graphs in (
            ("disable", ["equipment-area-capture", "another-workload"]),
            ("enable", ["equipment-area-capture"]),
        ):
            with self.subTest(action=action):
                result, _, updates = self.run_mode(action, graphs)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(updates, [])
        result, _, updates = self.run_mode(
            "disable",
            ["equipment-area-capture"],
            next_link="https://management.azure.com/next-page",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("paginated", result.stderr)
        self.assertEqual(updates, [])


if __name__ == "__main__":
    unittest.main()
