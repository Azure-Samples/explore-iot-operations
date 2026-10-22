"""Keep complete customer manifests consistent with the published graph contracts."""
import copy
import json
import runpy
import shutil
import unittest
import uuid
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parent
PREPARE = runpy.run_path(str(SCRIPTS / "prepare-release.py"))


class ManifestTests(unittest.TestCase):
    def test_complete_manifests_use_matching_published_contracts(self):
        directory = Path(__file__).resolve().parents[1] / "manifests"
        registry = yaml.safe_load((directory / "registry.yaml").read_text())
        self.assertEqual(registry["spec"]["host"], "ghcr.io")
        for name, artifact, inputs, output in (
            ("align-by-time", "align-by-time", ["speed", "temperature"], "aligned"),
            ("correlate-predictions", "correlate-by-id", ["predictions", "measurements"], "matches"),
            ("report-by-exception", "report-by-exception", ["report-readings", "report-ticks"], "changes"),
            ("stable-alarm", "stable-alarm", ["alarm-readings", "alarm-ticks"], "alarms"),
            ("offline-detection", "offline-detection", ["availability-readings", "availability-ticks", "availability-registers"], "availability"),
            ("running-total", "running-total", ["total-readings", "total-resets"], "totals"),
            ("smooth-readings", "smooth-readings", ["smoothing-readings"], "smoothed"),
        ):
            with self.subTest(name=name):
                resource = yaml.safe_load((directory / f"{name}.yaml").read_text())
                self.assertEqual(resource["kind"], "DataflowGraph")
                self.assertEqual(resource["metadata"]["name"], name)
                self.assertEqual(resource["metadata"]["namespace"], registry["metadata"]["namespace"])
                spec = resource["spec"]
                self.assertEqual(spec["profileRef"], "default")
                self.assertEqual(spec["mode"], "Enabled")
                nodes = {node["name"]: node for node in spec["nodes"]}
                self.assertEqual(nodes["source"]["sourceSettings"]["endpointRef"], "factory-mqtt")
                self.assertEqual(nodes["destination"]["destinationSettings"]["endpointRef"], "factory-mqtt")
                self.assertEqual(set(nodes), {"source", "processor", "destination"})
                self.assertEqual(nodes["source"]["sourceSettings"]["dataSources"],
                                 [f"factory/{topic}" for topic in inputs])
                expected_settings = {
                    "registryEndpointRef": registry["metadata"]["name"],
                    "artifact": "azure-samples/explore-iot-operations/dataflow-patterns/"
                                f"graph-{artifact}:1.0.0-rc.3",
                }
                if name not in ("align-by-time", "correlate-predictions"):
                    definition = yaml.safe_load((SCRIPTS.parent / f"graph-{artifact}.yaml").read_text())
                    default = definition["moduleConfigurations"][0]["parameters"]["settings"]["default"]
                    settings = json.loads(default)
                    settings.update({
                        "report-by-exception": {"heartbeatIntervalMs": 1000},
                        "stable-alarm": {"high": 80, "low": 70, "raiseForMs": 1000,
                                         "clearForMs": 500, "maxObservationGapMs": 1500},
                        "offline-detection": {"timeoutMs": 1000},
                    }.get(name, {}))
                    configuration = nodes["processor"]["graphSettings"]["configuration"]
                    self.assertEqual(len(configuration), 1)
                    self.assertEqual(configuration[0]["key"], "settings")
                    self.assertEqual(json.loads(configuration[0]["value"]), settings)
                    expected_settings["configuration"] = configuration
                    self.assertEqual(set(settings["inputTopics"].values()),
                                     {f"factory/{topic}" for topic in inputs})
                self.assertEqual(nodes["processor"]["graphSettings"], expected_settings)
                self.assertEqual(nodes["destination"]["destinationSettings"]["dataDestination"],
                                 f"factory/{output}")
                self.assertEqual(spec["nodeConnections"], [
                    {"from": {"name": "source"}, "to": {"name": "processor"}},
                    {"from": {"name": "processor"}, "to": {"name": "destination"}},
                ])

    def test_all_checked_in_manifest_graphs_match_release(self):
        directory = SCRIPTS.parent / "manifests"
        for path in directory.glob("*.yaml"):
            for resource in yaml.safe_load_all(path.read_text()):
                if resource["kind"] != "DataflowGraph":
                    continue
                for node in resource["spec"]["nodes"]:
                    if "graphSettings" not in node:
                        continue
                    artifact = node["graphSettings"]["artifact"]
                    graph, version = artifact.rsplit("/", 1)[1].split(":")
                    with self.subTest(path=path, graph=graph):
                        self.assertIn(graph, PREPARE["GRAPHS"])
                        self.assertEqual(version, "1.0.0-rc.3")
                        definition = yaml.safe_load((SCRIPTS.parent / f"{graph}.yaml").read_text())
                        # Source crate versions need not equal a future release:
                        # prepare-release stamps the actual published graph copy.
                        released = PREPARE["stamp_graph"](definition, version)
                        PREPARE["validate_graph"](released, version)

    def test_stamp_all_graph_refs_and_preserve_manifest_contract(self):
        workspace = SCRIPTS / ".work" / f"manifest-test-{uuid.uuid4().hex}"
        workspace.mkdir(parents=True)
        try:
            registry = {
                "kind": "RegistryEndpoint",
                "metadata": {"name": "artifacts", "namespace": "example"},
                "spec": {"host": "ghcr.io", "authentication": {"method": "Anonymous"}},
            }
            (workspace / "registry.yaml").write_text(yaml.safe_dump(registry))
            nodes = [
                {"name": f"{name}-{index}", "graphSettings": {
                    "registryEndpointRef": "artifacts",
                    "artifact": f"{prefix}{PREPARE['REPOSITORY']}/{name}:1.0.0-rc.3",
                }}
                for name in PREPARE["GRAPHS"] for index, prefix in enumerate(("", "ghcr.io/"))
            ]
            original = {
                "kind": "DataflowGraph",
                "metadata": {"name": "example", "namespace": "example"},
                "spec": {"nodes": nodes, "profileRef": "default", "mode": "Enabled"},
            }
            path = workspace / "graphs.yml"
            path.write_text(yaml.safe_dump_all([original, {"kind": "ConfigMap", "data": {"keep": "as is"}}]))
            expected = copy.deepcopy(original)
            for node in expected["spec"]["nodes"]:
                artifact = node["graphSettings"]["artifact"]
                node["graphSettings"]["artifact"] = artifact.rsplit(":", 1)[0] + ":12.34.56-preview.7"
            PREPARE["stamp_manifests"](workspace, "12.34.56-preview.7")
            self.assertEqual(list(yaml.safe_load_all(path.read_text())),
                             [expected, {"kind": "ConfigMap", "data": {"keep": "as is"}}])
            self.assertEqual(yaml.safe_load((workspace / "registry.yaml").read_text()), registry)
            valid = original["spec"]["nodes"][0]["graphSettings"]["artifact"]
            for artifact, host, reference in (
                (valid.replace(PREPARE["REPOSITORY"], "foreign/repository"), "ghcr.io", "artifacts"),
                (f"{PREPARE['REPOSITORY']}/graph-unknown:1.0.0-rc.3", "ghcr.io", "artifacts"),
                (valid + "@sha256:abc", "ghcr.io", "artifacts"),
                (valid.replace("1.0.0-rc.3", "invalid"), "ghcr.io", "artifacts"),
                ("other.example/" + valid, "ghcr.io", "artifacts"),
                (valid, "other.example", "artifacts"),
                (valid, "ghcr.io", "unknown"),
            ):
                with self.subTest(artifact=artifact, host=host, reference=reference):
                    invalid = copy.deepcopy(original)
                    invalid["spec"]["nodes"][0]["graphSettings"].update(
                        artifact=artifact, registryEndpointRef=reference)
                    path.write_text(yaml.safe_dump(invalid))
                    registry["spec"]["host"] = host
                    (workspace / "registry.yaml").write_text(yaml.safe_dump(registry))
                    with self.assertRaises(ValueError):
                        PREPARE["stamp_manifests"](workspace, "12.34.56-preview.7")
        finally:
            shutil.rmtree(workspace)


if __name__ == "__main__":
    unittest.main()
