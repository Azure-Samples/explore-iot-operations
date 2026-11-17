import copy
import itertools
import json
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from collector import Collector, read_evidence, read_records
from inspection import encode, select_snapshot, utc, validate_scenarios

SCENARIOS = json.loads((Path(__file__).resolve().parents[1] / "scenarios.json").read_text())
SCENARIOS[0]["classLabels"] = {
    str(index): label for index, label in enumerate(SCENARIOS[0]["policy"]["labels"])
}
SCENARIOS[1]["classLabels"] = {"0": "person", "56": "chair"}


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.media = self.root / "media"
        self.state = self.root / "state"
        self.responses = self.root / "responses"
        self.responses.mkdir()
        self.store = Collector(SCENARIOS, self.state, self.media, self.responses, timeout=30)
        self.scenario = SCENARIOS[0]
        self.relative = (
            "recordings/edge-pcb-camera/rtsp/edge-pcb-camera/camera-snapshots/snapshot.jpg"
        )
        self.image = self.media / self.relative
        self.image.parent.mkdir(parents=True)
        self.image.write_bytes(b"unit-test snapshot bytes")
        self.capture = {
            "Result": {
                "SourceType": "snapshot-to-fs",
                "SourceFiles": [
                    {
                        "Path": "private-buffer/snapshot.jpg",
                        "TargetPath": self.relative,
                        "CopyStatus": "Copied",
                        "OffsetFromEventTimeMilliseconds": -120,
                    }
                ],
            },
        }
        self.detection = {"label": "short", "confidence": 0.8, "box": [10, 20, 30, 40]}

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def trigger(self, inspection_id, scenario=None):
        return {
            "inspectionId": inspection_id,
            "assetId": (scenario or self.scenario)["assetName"],
            "eventTime": utc(998),
            "triggeredAt": utc(1000),
            "context": {"workOrder": "work-42"},
        }

    def send(self, inspection_id, stage, value, now=1001, scenario=None):
        self.store.ingest(
            (scenario or self.scenario)["name"],
            stage,
            inspection_id,
            encode(value).encode(),
            now=now,
        )

    def observation(self, inspection_id):
        row = self.store.db.execute(
            "SELECT observation FROM inspections WHERE id=?",
            (inspection_id,),
        ).fetchone()
        return json.loads(row[0]) if row and row[0] else None

    def inference(self, detections=(), scenario=None, relative=None):
        scenario = scenario or self.scenario
        labels = {label: int(key) for key, label in scenario["classLabels"].items()}
        rows = [item["box"] + [item["confidence"], labels[item["label"]]] for item in detections]
        rows.extend([[0, 0, 0, 0, 0, 0] for _ in range(scenario["outputRows"] - len(rows))])
        filename = str(uuid.uuid4())
        (self.responses / filename).write_text(encode({"detections_0": [rows]}))
        return {
            "Result": {
                "model": scenario["modelName"],
                "inferenceTimeMs": 12.5,
                "input": {
                    "contentType": "image/jpeg",
                    "data": list("/".join((relative or self.relative).split("/")[-5:]).encode()),
                },
                "output": {"contentType": "text/plain", "data": list(filename.encode())},
            }
        }

    def complete(self, inspection_id, result, capture=None):
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        self.send(inspection_id, "capture", self.capture if capture is None else capture)
        self.send(inspection_id, "inference", self.inference())
        self.send(inspection_id, "result", result)
        return self.observation(inspection_id)

    def test_out_of_order_stages_preserve_correlated_evidence(self):
        for stages in itertools.permutations(("trigger", "capture", "inference", "result")):
            with self.subTest(stages=stages):
                inspection_id = str(uuid.uuid4())
                messages = {
                    "trigger": self.trigger(inspection_id),
                    "capture": self.capture,
                    "inference": self.inference([self.detection]),
                    "result": [self.detection],
                }
                for stage in stages:
                    self.send(inspection_id, stage, messages[stage])
                result = self.observation(inspection_id)
                self.assertEqual(result["status"], "REVIEW")
                self.assertEqual(result["context"], {"workOrder": "work-42"})
                self.assertEqual(
                    (self.state / result["evidence"]["file"]).read_bytes(), self.image.read_bytes()
                )
                self.assertEqual(result["reviewDetections"], [self.detection])

    def test_missing_stages_and_late_result_are_errors(self):
        for missing in ("trigger", "capture", "inference", "result"):
            with self.subTest(missing=missing):
                inspection_id = str(uuid.uuid4())
                values = {
                    "trigger": self.trigger(inspection_id),
                    "capture": self.capture,
                    "inference": self.inference(),
                    "result": [],
                }
                for stage, value in values.items():
                    if stage != missing:
                        self.send(inspection_id, stage, value)
                self.assertIsNone(self.observation(inspection_id))
                self.store.tick(now=1032)
                self.assertEqual(self.observation(inspection_id)["status"], "ERROR")
                self.send(inspection_id, missing, values[missing], now=1033)
                self.assertEqual(self.observation(inspection_id)["status"], "ERROR")
        inspection_id = str(uuid.uuid4())
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        self.send(inspection_id, "capture", self.capture)
        self.send(inspection_id, "inference", self.inference())
        self.send(inspection_id, "result", [], now=1031)
        self.assertEqual(self.observation(inspection_id)["status"], "ERROR")

    def test_invalid_outputs_and_inference_errors_never_become_no_finding(self):
        for output in (
            {
                "Error": {
                    "model": "edge-pcb-quality",
                    "error": {"code": 500, "message": "Model unavailable"},
                }
            },
            {"Result": {"output": {"data": []}}},
            {"succeeded": True, "detections": []},
            [None],
            [{"label": "short", "confidence": True, "box": [1, 2, 3, 4]}],
            [{"label": "short", "confidence": 0.8, "box": [4, 2, 1, 3]}],
            [{"label": "wrong-model-label", "confidence": 0.8, "box": [1, 2, 3, 4]}],
        ):
            with self.subTest(output=output):
                result = self.complete(str(uuid.uuid4()), output)
                self.assertEqual(result["status"], "ERROR")
        inspection_id = str(uuid.uuid4())
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        self.store.ingest("pcb-quality", "result", inspection_id, b"[NaN]", now=1001)
        self.assertEqual(self.observation(inspection_id)["status"], "ERROR")

    def test_partial_capture_requires_review_even_with_no_detections(self):
        partial = copy.deepcopy(self.capture)
        partial["Error"] = {
            "Code": "PartialFailure",
            "Message": "One requested file could not be copied",
        }
        result = self.complete(str(uuid.uuid4()), [], partial)
        self.assertEqual(result["status"], "REVIEW")
        self.assertTrue(result["captureWarnings"])
        self.assertIn("evidence", result)
        self.assertEqual(self.complete(str(uuid.uuid4()), [])["status"], "NO_FINDING")

    def test_snapshot_selection_matches_graph_and_rejects_escaping_paths(self):
        capture = copy.deepcopy(self.capture)
        earlier = capture["Result"]["SourceFiles"][0]
        earlier["OffsetFromEventTimeMilliseconds"] = -100
        earlier["CopyStatus"] = "Skipped"
        later = {
            **earlier,
            "TargetPath": self.relative.replace("snapshot.jpg", "later.jpg"),
            "OffsetFromEventTimeMilliseconds": 100,
        }
        capture["Result"]["SourceFiles"] = [later, earlier]
        selected, _ = select_snapshot(capture, self.scenario)
        self.assertEqual(selected, earlier)
        for invalid in (
            "/etc/passwd",
            "../snapshot.jpg",
            self.relative.replace("edge-pcb-camera", "other-camera"),
        ):
            bad = copy.deepcopy(self.capture)
            bad["Result"]["SourceFiles"][0]["TargetPath"] = invalid
            self.assertEqual(self.complete(str(uuid.uuid4()), [], bad)["status"], "ERROR")

    def test_evidence_missing_or_symlink_is_an_error(self):
        self.image.unlink()
        self.assertEqual(self.complete(str(uuid.uuid4()), [])["status"], "ERROR")
        outside = self.root / "outside.jpg"
        outside.write_bytes(b"not a capture")
        self.image.symlink_to(outside)
        self.assertEqual(self.complete(str(uuid.uuid4()), [])["status"], "ERROR")

    def test_duplicates_restart_outbox_and_retention(self):
        inspection_id = str(uuid.uuid4())
        first = self.complete(inspection_id, [])
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        self.send(inspection_id, "result", [])
        self.store.close()
        self.store = Collector(SCENARIOS, self.state, self.media, self.responses, timeout=30)
        self.assertEqual(len(self.store.pending_publications()), 1)
        self.assertEqual(self.observation(inspection_id), first)
        self.store.mark_published(inspection_id)
        self.assertEqual(len(self.store.pending_publications()), 0)
        unrelated = self.state / "customer-file.txt"
        unrelated.write_text("keep")
        pending_id = str(uuid.uuid4())
        self.complete(pending_id, [])
        self.store.prune(1, now=1000 + 2 * 86400)
        self.assertIsNone(self.observation(inspection_id))
        self.assertIsNotNone(self.observation(pending_id))
        self.assertTrue(unrelated.exists())
        self.assertFalse((self.state / f"{inspection_id}.jpg").exists())

    def test_conflicting_duplicate_is_not_silently_matched(self):
        inspection_id = str(uuid.uuid4())
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        self.send(inspection_id, "result", [])
        self.send(inspection_id, "result", [self.detection])
        self.assertEqual(self.observation(inspection_id)["status"], "ERROR")
        with self.assertRaisesRegex(ValueError, "reused across scenarios"):
            self.send(inspection_id, "result", [], scenario=SCENARIOS[1])

    def test_raw_tensor_prevents_false_clean_results_and_wrong_evidence(self):
        for fault in ("short-row", "wrong-image", "dropped-detection", "wrong-label"):
            with self.subTest(fault=fault):
                inspection_id = str(uuid.uuid4())
                raw = self.inference([self.detection])
                result = [self.detection]
                if fault == "short-row":
                    filename = bytes(raw["Result"]["output"]["data"]).decode()
                    tensor = json.loads((self.responses / filename).read_text())
                    tensor["detections_0"][0][0] = [1, 2]
                    (self.responses / filename).write_text(encode(tensor))
                    result = []
                elif fault == "wrong-image":
                    raw["Result"]["input"]["data"] = list(b"another-image.jpg")
                elif fault == "dropped-detection":
                    result = []
                else:
                    result = [{**self.detection, "label": "open_circuit"}]
                self.send(inspection_id, "trigger", self.trigger(inspection_id))
                self.send(inspection_id, "capture", self.capture)
                self.send(inspection_id, "inference", raw)
                self.send(inspection_id, "result", result)
                self.assertEqual(self.observation(inspection_id)["status"], "ERROR")

    def test_area_rule_uses_model_coordinates_and_only_configured_label(self):
        scenario = SCENARIOS[1]
        capture = copy.deepcopy(self.capture)
        relative = self.relative.replace("edge-pcb-camera", "edge-area-camera")
        image = self.media / relative
        image.parent.mkdir(parents=True)
        image.write_bytes(self.image.read_bytes())
        capture["Result"]["SourceFiles"][0]["TargetPath"] = relative
        for box, label, confidence, expected in (
            ([150, 284, 304, 480], "person", 0.91, "REVIEW"),
            ([0, 0, 10, 10], "person", 0.91, "NO_FINDING"),
            ([150, 284, 304, 480], "person", 0.40, "NO_FINDING"),
            ([150, 284, 304, 480], "chair", 0.91, "NO_FINDING"),
        ):
            with self.subTest(box=box, label=label, confidence=confidence):
                inspection_id = str(uuid.uuid4())
                detections = [{"box": box, "label": label, "confidence": confidence}]
                self.send(
                    inspection_id,
                    "trigger",
                    self.trigger(inspection_id, scenario),
                    scenario=scenario,
                )
                self.send(inspection_id, "capture", capture, scenario=scenario)
                self.send(
                    inspection_id,
                    "inference",
                    self.inference(detections, scenario, relative),
                    scenario=scenario,
                )
                self.send(
                    inspection_id,
                    "result",
                    detections if confidence >= 0.55 else [],
                    scenario=scenario,
                )
                self.assertEqual(self.observation(inspection_id)["status"], expected)

    def test_misconfigured_policies_fail_before_processing(self):
        for name, configure in (
            ("unknown-label", lambda scenarios: scenarios[1]["policy"].update(label="people")),
            ("boolean-threshold", lambda scenarios: scenarios[0].update(confidenceThreshold=True)),
            ("zero-threshold", lambda scenarios: scenarios[0].update(confidenceThreshold="0")),
            (
                "shared-topic",
                lambda scenarios: scenarios[1].update(topicPrefix=scenarios[0]["topicPrefix"]),
            ),
            ("missing-model", lambda scenarios: scenarios[0].pop("modelName")),
            ("wrong-row-count", lambda scenarios: scenarios[0].update(outputRows=299)),
        ):
            with self.subTest(fault=name):
                scenarios = copy.deepcopy(SCENARIOS)
                configure(scenarios)
                with self.assertRaises(ValueError):
                    validate_scenarios(scenarios)

    def test_record_lookup_export_and_pending_outbox(self):
        inspection_id = str(uuid.uuid4())
        observation = self.complete(inspection_id, [])
        self.assertEqual(read_records(self.state, inspection_id), [observation])
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve().parents[1] / "mqtt_client.py"),
                "--scenarios",
                str(self.root / "missing-scenarios.json"),
                "records",
                "--state",
                str(self.state),
                "--inspection-id",
                inspection_id,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), observation)
        self.assertEqual(read_evidence(self.state, inspection_id), self.image.read_bytes())
        self.assertEqual(read_records(self.state, pending=True)[0]["state"], "awaiting-publication")
        self.store.mark_published(inspection_id)
        pending_id = str(uuid.uuid4())
        self.send(pending_id, "trigger", self.trigger(pending_id))
        self.assertEqual(
            [(row["inspectionId"], row["state"]) for row in read_records(self.state, pending=True)],
            [(pending_id, "awaiting-stages")],
        )
        with self.assertRaisesRegex(ValueError, "No completed observation"):
            read_records(self.state, str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            read_evidence(self.state, "../../unrelated-file")
        evidence = self.state / observation["evidence"]["file"]
        evidence.write_bytes(b"modified after inspection")
        with self.assertRaisesRegex(ValueError, "checksum"):
            read_evidence(self.state, inspection_id)
        evidence.unlink()
        evidence.symlink_to(self.image)
        with self.assertRaises(OSError):
            read_evidence(self.state, inspection_id)

    def test_configuration_changes_require_a_drained_observer(self):
        inspection_id = str(uuid.uuid4())
        self.send(inspection_id, "trigger", self.trigger(inspection_id))
        changed = copy.deepcopy(SCENARIOS)
        changed[1]["policy"]["region"] = [0.2, 0.2, 0.8, 0.8]
        with self.assertRaisesRegex(ValueError, "Configuration changed"):
            Collector(changed, self.state, self.media, self.responses)
        self.complete(inspection_id, [])
        with self.assertRaisesRegex(ValueError, "Configuration changed"):
            Collector(changed, self.state, self.media, self.responses)
        self.store.mark_published(inspection_id)
        self.store.close()
        self.store = Collector(changed, self.state, self.media, self.responses)
        self.assertEqual(self.observation(inspection_id)["policy"], SCENARIOS[0]["policy"])

    def test_invalid_business_context_produces_an_error(self):
        inspection_id = str(uuid.uuid4())
        trigger = {**self.trigger(inspection_id), "context": ["not", "an", "object"]}
        self.send(inspection_id, "trigger", trigger)
        self.assertEqual(self.observation(inspection_id)["status"], "ERROR")
        self.assertIn("context", self.observation(inspection_id)["reason"])


if __name__ == "__main__":
    unittest.main()
