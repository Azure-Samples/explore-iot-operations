#!/usr/bin/env python3
"""Check deployed-resource comparisons without running a broker or operator."""
import contextlib
import copy
import io
import json
from pathlib import Path
import shutil
import sys
import unittest
from unittest.mock import patch
import uuid

import yaml


SCRIPTS = Path(__file__).resolve().parent


class DeployedTests(unittest.TestCase):
    def test_server_defaults_are_accepted_but_live_graph_drift_is_rejected(self):
        script = (SCRIPTS / "verify-deployed.sh").read_text()
        self.assertIn('-o yaml > "$work/validated-manifest.yaml"', script)
        self.assertIn('python3 - "$work/validated-manifest.yaml"', script)
        check = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        graphs = [{
            "kind": "DataflowGraph",
            "metadata": {"name": f"sample-{i}"},
            "spec": {
                "profileRef": "single",
                "mode": "Enabled",
                "nodes": [
                    {"nodeType": "Source", "sourceSettings": {"dataSources": ["isolated/input"]}},
                    {"nodeType": "Graph", "graphSettings": {"configuration": []}},
                    {"nodeType": "Destination", "destinationSettings": {"headers": []}},
                ],
                "nodeConnections": [],
            },
        } for i in range(3)]
        profile = {"spec": {"instanceCount": 1}}
        work = SCRIPTS / ".work" / f"deployed-test-{uuid.uuid4().hex}"
        work.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, work)
        manifest = work / "validated-manifest.yaml"
        live = copy.deepcopy(graphs)

        def get(command, **kwargs):
            self.assertEqual(command[:6], [
                "kubectl", "--kubeconfig", "explicit-config", "--namespace", "sample", "get",
            ])
            value = profile if command[6] == "dataflowprofile" else next(
                g for g in live if g["metadata"]["name"] == command[7])
            return json.dumps(value)

        with patch.object(sys, "argv", [
            "-", str(manifest), "explicit-config", "sample", str(work),
        ]), patch("subprocess.check_output", side_effect=get):
            for documents in ([{"kind": "List", "items": graphs}], graphs):
                manifest.write_text(yaml.safe_dump_all(documents))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    exec(compile(check, "verify-deployed.sh", "exec"), {})
                self.assertEqual(output.getvalue().strip(), "isolated")
                self.assertTrue((work / "live-resources.json").is_file())
            live[0]["spec"]["nodes"][1]["graphSettings"]["configuration"] = [
                {"name": "changed", "value": "not the installed configuration"},
            ]
            with self.assertRaisesRegex(AssertionError, "Live graph differs"):
                exec(compile(check, "verify-deployed.sh", "exec"), {})


if __name__ == "__main__":
    unittest.main()
