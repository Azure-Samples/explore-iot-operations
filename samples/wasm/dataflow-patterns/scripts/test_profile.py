#!/usr/bin/env python3
"""Exercise Helm's live lookup against a local, read-only API test double."""
import json
import shutil
import subprocess
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parent
GROUP = "connectivity.iotoperations.azure.com"
VERSION = f"{GROUP}/v1"


class ProfileTests(unittest.TestCase):
    def test_existing_profile_is_verified_but_never_rendered_or_modified(self):
        work = SCRIPTS / ".work" / f"profile-{uuid.uuid4().hex}"
        work.mkdir(parents=True)
        requests = []
        profile = {"apiVersion": VERSION, "kind": "DataflowProfile",
                   "metadata": {"name": "existing", "namespace": "sample"},
                   "spec": {"instanceCount": 1}}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                path = self.path.split("?")[0]
                requests.append(("GET", path))
                group = {"name": GROUP, "versions": [{"groupVersion": VERSION, "version": "v1"}],
                         "preferredVersion": {"groupVersion": VERSION, "version": "v1"}}
                routes = {
                    "/version": {"major": "1", "minor": "32", "gitVersion": "v1.32.0"},
                    "/api": {"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]},
                    "/apis": {"kind": "APIGroupList", "apiVersion": "v1", "groups": [group]},
                    "/api/v1": {"kind": "APIResourceList", "apiVersion": "v1",
                                "groupVersion": "v1", "resources": []},
                    f"/apis/{GROUP}": dict(group, kind="APIGroup", apiVersion="v1"),
                    f"/apis/{VERSION}": {
                        "kind": "APIResourceList", "apiVersion": "v1", "groupVersion": VERSION,
                        "resources": [
                            {"name": plural, "singularName": singular, "namespaced": True,
                             "kind": kind, "verbs": ["get"]}
                            for plural, singular, kind in (
                                ("dataflowprofiles", "dataflowprofile", "DataflowProfile"),
                                ("dataflowgraphs", "dataflowgraph", "DataflowGraph"),
                                ("registryendpoints", "registryendpoint", "RegistryEndpoint"),
                            )
                        ],
                    },
                    f"/apis/{VERSION}/namespaces/sample/dataflowprofiles/existing": profile,
                }
                value = routes.get(path)
                self.send_response(200 if value else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(value or {
                    "kind": "Status", "apiVersion": "v1", "reason": "NotFound",
                    "message": "Not found", "code": 404,
                }).encode())

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            config = work / "kubeconfig"
            config.write_text(yaml.safe_dump({
                "apiVersion": "v1", "kind": "Config", "current-context": "unit-test",
                "clusters": [{"name": "test", "cluster": {
                    "server": f"http://127.0.0.1:{server.server_port}"}}],
                "users": [{"name": "test", "user": {}}],
                "contexts": [{"name": "unit-test", "context": {"cluster": "test", "user": "test"}}],
            }))
            command = [
                "helm", "template", "test", str(SCRIPTS.parent / "chart"), "--namespace", "sample",
                "--kubeconfig", str(config), "--dry-run=server", "--disable-openapi-validation",
                "--set", "profile.create=false", "--set", "profileRef=existing",
            ]
            for count in (1, 2, None):
                profile["spec"] = {} if count is None else {"instanceCount": count}
                result = subprocess.run(command, text=True, capture_output=True, timeout=30)
                if count == 1:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    resources = list(yaml.safe_load_all(result.stdout))
                    self.assertFalse(any(r["kind"] == "DataflowProfile" for r in resources))
                    graphs = [r for r in resources if r["kind"] == "DataflowGraph"]
                    self.assertEqual(len(graphs), 3)
                    self.assertTrue(all(r["spec"]["profileRef"] == "existing" for r in graphs))
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("instanceCount must equal 1", result.stderr)
            result = subprocess.run(command[:-1] + ["profileRef=missing"],
                                    text=True, capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be readable", result.stderr)
            self.assertIn(("GET", f"/apis/{VERSION}/namespaces/sample/dataflowprofiles/existing"),
                          requests)
            self.assertTrue(all(method == "GET" for method, _ in requests))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()
