import copy
import json
import re
import tempfile
import unittest
from pathlib import Path

import jsonschema
import yaml

import render


def configuration() -> dict:
    config = json.loads((render.ROOT / "config.example.json").read_text())
    config.update(
        subscriptionId="11111111-2222-4333-8444-555555555555",
        resourceGroup="sample-rg",
        aioInstanceName="sample-aio",
        customLocationName="sample-location",
        kubeContext="sample-context",
        adrNamespaceName="sample-adr",
        adrNamespaceLocation="eastus",
        cameraUrl="rtsp://camera.example/stream",
        foundryTrustSecret="foundry-ca",
        modelRegistrySecret="model-registry",
        registry="sample.azurecr.io",
        registryEndpointName="sample-registry",
        storageClassName="rwx",
    )
    return config


class RenderingTests(unittest.TestCase):
    def test_renders_consistent_model_stores_and_initially_disabled_resources(self):
        config = configuration()
        config.update(cameraId="camera-two", modelName="person-two", artifactVersion="1.2.3")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            path = output / "config.json"
            path.write_text(json.dumps(config))
            render.render(render.load_config(path), output)
            connector = json.loads((output / "connector.parameters.json").read_text())["parameters"]
            dataflow = json.loads((output / "dataflow.parameters.json").read_text())["parameters"]
            camera = json.loads((output / "camera.parameters.json").read_text())["parameters"]
            model = yaml.safe_load((output / "model.yaml").read_text())
            self.assertEqual(model["metadata"]["name"], connector["modelName"]["value"])
            self.assertEqual(connector["modelName"], dataflow["modelName"])
            self.assertEqual(dataflow["cameraId"], camera["cameraId"])
            self.assertEqual(dataflow["mode"]["value"], "Disabled")
            self.assertIs(camera["enabled"]["value"], False)
            self.assertEqual(model["spec"]["model"]["custom"]["tag"], "1.2.3")
            subjects = model["spec"]["authenticationMethods"][0]["roles"][0]["authorizedSubjects"]
            self.assertEqual(
                subjects[0]["serviceAccountName"], "aioappcfg-edge-predictive-inference-sa"
            )
            for name in ("storage", "reader", "cleanup"):
                raw = (output / f"{name}.yaml").read_text()
                self.assertNotIn("${", raw)
                self.assertIn(config["dataClaimName"], raw)
                list(yaml.safe_load_all(raw))
            for stage in ("preprocess", "postprocess"):
                graph = yaml.safe_load((output / f"{stage}-graph.yaml").read_text())
                self.assertEqual(
                    graph["operations"][1]["module"],
                    f"{render.REPOSITORY}/{stage}:1.2.3",
                )
                self.assertEqual(
                    set(graph["moduleConfigurations"][0]["parameters"]),
                    {"camera_id", "model_name", "score_threshold", "nms_threshold"},
                )
            for template in ("definition", "connector", "camera", "dataflow"):
                bicep = (render.ROOT / "bicep" / f"{template}.bicep").read_text()
                names = set(re.findall(r"^param (\w+) ", bicep, re.MULTILINE))
                parameters = json.loads((output / f"{template}.parameters.json").read_text())
                self.assertEqual(set(parameters["parameters"]), names)

    def test_rejects_bad_endpoints_secrets_thresholds_and_unknown_settings(self):
        cases = [
            {"cameraUrl": "rtsp://username:password@camera.example/stream"},
            {"modelEndpoint": "http://model.example"},
            {"modelEndpoint": "https://model.example/v1/predict"},
            {"modelEndpoint": "https://model.example?token=example"},
            {"topicPrefix": "edge/+/person"},
            {"dataClaimName": "../other"},
            {"scoreThreshold": 0},
            {"nmsThreshold": float("nan")},
            {"cameraAuthentication": {"method": "UsernamePassword", "password": "not-allowed"}},
            {"unknown": "setting"},
            {"resourceGroup": "REPLACE_WITH_RESOURCE_GROUP"},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            for override in cases:
                with self.subTest(override=override):
                    config = copy.deepcopy(configuration())
                    config.update(override)
                    path.write_text(json.dumps(config))
                    with self.assertRaises((ValueError, jsonschema.ValidationError)):
                        render.load_config(path)

    def test_preserves_yaml_types_and_supports_explicit_anonymous_camera(self):
        config = configuration()
        config["cameraAuthentication"] = {"method": "Anonymous"}
        config["modelEndpoint"] = "https://gateway.example:443/custom-model/"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            path = output / "config.json"
            path.write_text(json.dumps(config))
            loaded = render.load_config(path)
            self.assertEqual(loaded["modelEndpoint"], "https://gateway.example:443/custom-model")
            render.render(loaded, output)
            storage = list(yaml.safe_load_all((output / "storage.yaml").read_text()))
            self.assertEqual(storage[0]["spec"]["resources"]["requests"]["storage"], "2Gi")
            reader = list(yaml.safe_load_all((output / "reader.yaml").read_text()))[1]
            self.assertIs(reader["spec"]["volumes"][0]["persistentVolumeClaim"]["readOnly"], True)
            self.assertIs(reader["spec"]["automountServiceAccountToken"], False)


if __name__ == "__main__":
    unittest.main()
