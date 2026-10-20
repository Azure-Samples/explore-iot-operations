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
        profile = {"metadata": {"uid": "profile-uid"}, "spec": {"instanceCount": 1}}
        pod = {"metadata": {"creationTimestamp": "2026-10-20T20:00:00Z"},
               "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        health = {
            "metadata": {"ownerReferences": [{"uid": "profile-uid"}]},
            "data": {
                f"0.dfg.sample-{i}.{component}": json.dumps({
                    "s": "Available", "lu": "2026-10-20T20:00:01.123456789Z",
                })
                for i in range(3) for component in ("source", "transform", "destination")
            },
        }
        work = SCRIPTS / ".work" / f"deployed-test-{uuid.uuid4().hex}"
        work.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, work)
        manifest = work / "validated-manifest.yaml"
        live = copy.deepcopy(graphs)

        def get(command, **kwargs):
            self.assertEqual(command[:6], [
                "kubectl", "--kubeconfig", "explicit-config", "--namespace", "sample", "get",
            ])
            if command[6] in ("dataflowprofile", "pod", "configmap"):
                value = {"dataflowprofile": profile, "pod": pod, "configmap": health}[command[6]]
            else:
                value = next(g for g in live if g["metadata"]["name"] == command[7])
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

    def test_readiness_requires_current_health_and_ready_worker(self):
        script = (SCRIPTS / "verify-deployed.sh").read_text()
        check = script.split("<<'PY'\n", 1)[1].split("resources = []", 1)[0]
        scope = {}
        exec(compile(check, "verify-deployed.sh", "exec"), scope)
        graphs = [{"metadata": {"name": "sample"}, "spec": {"profileRef": "single"}}]
        profiles = {"single": {"metadata": {"uid": "owned-profile"}}}
        pod = {"metadata": {"creationTimestamp": "2026-10-20T20:00:00Z"},
               "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        health = {"metadata": {"ownerReferences": [{"uid": "owned-profile"}]},
                  "data": {f"0.dfg.sample.{component}": json.dumps({
                      "s": "Available", "lu": "2026-10-20T20:00:01Z",
                  }) for component in ("source", "transform", "destination")}}
        scope["get"] = lambda kind, *args, **kwargs: pod if kind == "pod" else health
        ready = lambda: scope["runtime_ready"](graphs, profiles)
        self.assertTrue(ready())
        for component in ("source", "transform", "destination"):
            key = f"0.dfg.sample.{component}"
            original = health["data"].pop(key)
            self.assertFalse(ready())
            for value in ({"s": "Initializing"}, {"s": "Failed"},
                          {"s": "Available", "lu": "2026-10-20T19:59:59Z"}):
                health["data"][key] = json.dumps(value)
                self.assertFalse(ready())
            health["data"][key] = original
        pod["status"]["conditions"][0]["status"] = "False"
        self.assertFalse(ready())
        pod["status"]["conditions"][0]["status"] = "True"
        pod["metadata"]["deletionTimestamp"] = "2026-10-20T20:01:00Z"
        self.assertFalse(ready())
        del pod["metadata"]["deletionTimestamp"]
        health["metadata"]["ownerReferences"][0]["uid"] = "different-profile"
        self.assertFalse(ready())
        scope["runtime_ready"] = unittest.mock.Mock(side_effect=[False, True])
        with patch("time.sleep"):
            scope["wait_for_runtime"](graphs, profiles)
        scope["runtime_ready"] = lambda *args: False
        with patch("time.monotonic", side_effect=[0, 2]), patch.dict(
                "os.environ", {"RUNTIME_READY_TIMEOUT": "1"}):
            with self.assertRaisesRegex(TimeoutError, "Runtime not ready"):
                scope["wait_for_runtime"](graphs, profiles)


if __name__ == "__main__":
    unittest.main()
