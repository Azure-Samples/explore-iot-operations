import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from test_render import configuration

import render

FAKE_TOOL = """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

tool = Path(sys.argv[0]).name
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps([tool, *sys.argv[1:]]) + "\\n")
if tool == "kubectl":
    if "deployments,statefulsets" in sys.argv:
        print(json.dumps({"items": [{
            "metadata": {"name": "existing-connector"},
            "spec": {"template": {"spec": {"containers": [{
                "image": "example.azurecr.io/inference-connector:0.1.2"
            }]}}}
        }]}))
    elif "persistentvolumeclaim" in sys.argv:
        print(json.dumps({"metadata": {"labels": {"app.kubernetes.io/part-of": "another-app"}}}))
    else:
        raise SystemExit("Unexpected kubectl call in isolated test")
"""


class DeploymentTests(unittest.TestCase):
    def run_action(self, action):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ("deploy.sh", "render.py", "config.schema.json"):
                shutil.copyfile(render.ROOT / name, directory / name)
            shutil.copytree(render.ROOT / "kubernetes", directory / "kubernetes")
            config = directory / "config.json"
            config.write_text(json.dumps(configuration()))
            tools = directory / "bin"
            tools.mkdir()
            for name in ("kubectl", "az"):
                tool = tools / name
                tool.write_text(FAKE_TOOL)
                tool.chmod(0o755)
            log = directory / "calls.jsonl"
            environment = {
                **os.environ,
                "PATH": os.pathsep.join(
                    [str(tools), str(Path(sys.executable).parent), os.environ["PATH"]]
                ),
                "CALL_LOG": str(log),
            }
            result = subprocess.run(
                ["bash", str(directory / "deploy.sh"), action, str(config)],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            calls = (
                [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            )
            return result, calls

    def test_enables_graph_before_camera_and_keeps_subscription_explicit(self):
        result, calls = self.run_action("enable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["az", "az"])
        self.assertIn("mode=Enabled", calls[0])
        self.assertIn("enabled=true", calls[1])
        self.assertTrue(
            all("--subscription" in call and "--resource-group" in call for call in calls)
        )

    def test_rejects_an_existing_connector_without_any_deployment(self):
        result, calls = self.run_action("connector")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Do not deploy a second connector", result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("--context", calls[0])
        self.assertIn("sample-context", calls[0])

    def test_refuses_to_change_an_unrelated_data_claim(self):
        result, calls = self.run_action("storage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite unrelated", result.stderr)
        self.assertFalse(any("apply" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
