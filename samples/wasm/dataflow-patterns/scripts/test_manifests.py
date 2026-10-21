"""Keep complete customer manifests consistent with the published graph contracts."""
import unittest
from pathlib import Path

import yaml


class ManifestTests(unittest.TestCase):
    def test_complete_manifests_use_matching_published_contracts(self):
        directory = Path(__file__).resolve().parents[1] / "manifests"
        registry = yaml.safe_load((directory / "registry.yaml").read_text())
        self.assertEqual(registry["spec"]["host"], "ghcr.io")
        for name, artifact, inputs, output in (
            ("align-by-time", "align-by-time", ["speed", "temperature"], "aligned"),
            ("correlate-predictions", "correlate-by-id", ["predictions", "measurements"], "matches"),
        ):
            with self.subTest(name=name):
                resource = yaml.safe_load((directory / f"{name}.yaml").read_text())
                self.assertEqual(resource["kind"], "DataflowGraph")
                self.assertEqual(resource["metadata"]["name"], name)
                self.assertEqual(resource["metadata"]["namespace"], registry["metadata"]["namespace"])
                spec = resource["spec"]
                nodes = {node["name"]: node for node in spec["nodes"]}
                self.assertEqual(set(nodes), {"source", "processor", "destination"})
                self.assertEqual(nodes["source"]["sourceSettings"]["dataSources"],
                                 [f"factory/{topic}" for topic in inputs])
                self.assertEqual(nodes["processor"]["graphSettings"], {
                    "registryEndpointRef": registry["metadata"]["name"],
                    "artifact": "azure-samples/explore-iot-operations/dataflow-patterns/"
                                f"graph-{artifact}:1.0.0-rc.2",
                })
                self.assertEqual(nodes["destination"]["destinationSettings"]["dataDestination"],
                                 f"factory/{output}")
                self.assertEqual(spec["nodeConnections"], [
                    {"from": {"name": "source"}, "to": {"name": "processor"}},
                    {"from": {"name": "processor"}, "to": {"name": "destination"}},
                ])


if __name__ == "__main__":
    unittest.main()
