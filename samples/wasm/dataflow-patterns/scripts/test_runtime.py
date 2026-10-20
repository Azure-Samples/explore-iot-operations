#!/usr/bin/env python3
"""Offline core replay and verifier checks, NOT deployed AIO/MQTT validation.

The replay executable runs the actual Rust core. The Python SDK/filter projection
below is an explicit model of wrapper.rs and the fixed component filter, not a
substitute for running the SDK. Existing native SDK wrapper
tests are also executed; only verify_runtime.py against a broker tests deployment.
"""
import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parent
BASE = SCRIPTS.parent
SPEC = importlib.util.spec_from_file_location(
    "verify_runtime", BASE / "chart" / "files" / "verify_runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime
SPEC.loader.exec_module(runtime)
BASE_TIME = datetime(2026, 10, 19, 10, tzinfo=timezone.utc)
CARGO = ["cargo", "+1.90.0"]


def pack(records):
    if not records:
        return {"kind": "pending"}
    return records[0] if len(records) == 1 else {"kind": "batch", "records": records}


def sdk_projection(value):
    """Model only: wrapper::data_output strips diagnostics, then repacks."""
    if value.get("kind") == "diagnostic":
        return {"kind": "pending"}
    if value.get("kind") == "batch":
        return pack([record for record in value["records"] if record.get("kind") != "diagnostic"])
    return value


def graph_projection(role, core):
    value = sdk_projection(core)
    kind = value.get("kind")
    return None if kind in runtime.INTERNAL_KINDS else value


def diagnostics(value):
    if value.get("kind") == "batch":
        return [code for record in value["records"] for code in diagnostics(record)]
    return [value["code"]] if value.get("kind") == "diagnostic" else []


class CoreReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = SCRIPTS / ".work" / f"runtime-{uuid.uuid4().hex}"
        cls.workspace.mkdir(parents=True)
        cls.addClassCleanup(shutil.rmtree, cls.workspace)

    def cargo(self, *args):
        result = subprocess.run(
            [*CARGO, *args], cwd=BASE, text=True, capture_output=True,
            env={**os.environ, "TMPDIR": str(self.workspace)}, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def replay(self, fixture, name):
        path = self.workspace / f"{name}.json"
        path.write_text(json.dumps(fixture))
        output = self.cargo("run", "--locked", "--quiet", "--example", "replay", "--", str(path))
        values = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(len(values), len(fixture["steps"]))
        return values

    def test_existing_native_sdk_wrapper_tests(self):
        output = self.cargo("test", "--locked", "--quiet", "--lib", "wrapper::tests::")
        self.assertRegex(output, r"test result: ok\. [1-9][0-9]* passed")

    def test_mqtt_scenarios_against_actual_rust_core(self):
        for scenario in runtime.scenarios(BASE_TIME):
            with self.subTest(role=scenario.role):
                graph = yaml.safe_load((BASE / f"graph-{scenario.role}.yaml").read_text())
                configurations = {item["name"]: item["parameters"]
                                  for item in graph["moduleConfigurations"]}
                settings = json.loads(configurations["patterns"]["settings"]["default"])
                self.assertEqual(settings, scenario.configuration)
                self.assertNotIn("suppress-internal", configurations)
                operators = {op["operationType"]: op for op in graph["operations"]}
                self.assertEqual(operators["map"]["module"], operators["filter"]["module"])
                self.assertEqual(operators["filter"]["name"], "suppress-internal")
                fixture = {"configuration": settings, "steps": [
                    {"topic": step.topic, "input": step.payload,
                     "nowMs": int(BASE_TIME.timestamp() * 1000) + 10000 + index * 10}
                    for index, step in enumerate(scenario.steps)]}
                outputs = self.replay(fixture, scenario.role)
                actual, expected = [], []
                mixed_batches = 0
                for index, (step, core) in enumerate(zip(scenario.steps, outputs)):
                    with self.subTest(role=scenario.role, step=index, input=step.payload):
                        self.assertEqual(diagnostics(core), list(step.core_codes))
                        if step.core_kind:
                            self.assertEqual(core["kind"], step.core_kind)
                        elif step.expected is None and not step.core_codes:
                            self.assertEqual(core, {"kind": "pending"})
                        delivery = graph_projection(scenario.role, core)
                        self.assertEqual(delivery, step.expected)
                        if delivery is not None:
                            actual.append((scenario.destination, delivery))
                        if step.expected is not None:
                            expected.append((scenario.destination, step.expected))
                        runtime.assert_deliveries(actual, expected)
                        if core.get("kind") == "batch" and diagnostics(core):
                            mixed_batches += 1
                            self.assertEqual(len(core["records"]), 3)
                            self.assertEqual(len(delivery["records"]), 2)
                if scenario.role == "align-by-time":
                    self.assertEqual(mixed_batches, 1)

    def test_existing_fixtures_against_core_and_projection(self):
        for path in sorted((BASE / "fixtures").glob("*.json")):
            with self.subTest(fixture=path.name):
                fixture = json.loads(path.read_text())
                outputs = self.replay(fixture, f"fixture-{path.stem}")
                for step, core in zip(fixture["steps"], outputs):
                    self.assertEqual(graph_projection(fixture["configuration"]["role"], core),
                                     step["expected"])

    def test_real_core_diagnostic_batches_collapse_or_disappear(self):
        scenario = runtime.scenarios(BASE_TIME)[0]
        tick = next(step for step in scenario.steps
                    if step.expected and step.core_codes == ("noContext",))
        index = scenario.steps.index(tick)
        steps = scenario.steps[:index + 1]
        fixture = {"configuration": scenario.configuration, "steps": [
            {"input": step.payload, "nowMs": int(BASE_TIME.timestamp() * 1000) + 10000 + i * 10}
            for i, step in enumerate(steps)]}
        core = self.replay(fixture, "mixed-collapse")[-1]
        self.assertEqual(diagnostics(core), ["noContext"])
        self.assertEqual(len(core["records"]), 3)
        # A second replay retains one, then zero, context-eligible speed inputs.
        for keep in (1, 0):
            altered = copy.deepcopy(fixture)
            eligible = [step for step in altered["steps"]
                        if step["input"]["kind"] == "speed"
                        and step["input"]["assetId"] == "runtime-mixed"
                        and "pieceId" in step["input"]]
            remove = eligible[keep:]
            altered["steps"] = [step for step in altered["steps"] if step not in remove]
            output = self.replay(altered, f"mixed-{keep}")[-1]
            self.assertEqual(diagnostics(output), ["noContext"])
            delivery = graph_projection(scenario.role, output)
            self.assertEqual(delivery, tick.expected["records"][0] if keep else None)
        # Move all retained context after the three readings: the actual core
        # emits a diagnostic-only batch, which the wrapper repacks as pending.
        altered = copy.deepcopy(fixture)
        for step in altered["steps"]:
            payload = step["input"]
            if (payload["kind"] == "temperature" and payload["assetId"] == "runtime-mixed"
                    and payload["temperature"] != 99):
                payload["sampledAt"] = runtime.stamp(
                    BASE_TIME.replace(microsecond=900000, second=1))
        output = self.replay(altered, "diagnostic-only-batch")[-1]
        self.assertEqual(output["kind"], "batch")
        self.assertEqual(diagnostics(output), ["noContext"] * 3)
        self.assertEqual(sdk_projection(output), {"kind": "pending"})
        self.assertIsNone(graph_projection(scenario.role, output))


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.scenarios = runtime.scenarios(BASE_TIME)
        self.expected = [(scenario.destination, step.expected) for scenario in self.scenarios
                         for step in scenario.steps if step.expected is not None]

    def test_exact_shared_expectations_are_accepted_without_paho(self):
        runtime.assert_deliveries(self.expected, copy.deepcopy(self.expected))

    def test_partial_wrong_extra_duplicate_or_feedback_outputs_fail(self):
        for mutation in ("missing-field", "wrong-field", "extra-field", "missing-output",
                         "duplicate-output", "wrong-topic", "flatten-batch"):
            actual = copy.deepcopy(self.expected)
            if mutation == "missing-field":
                del actual[0][1]["temperatureSampledAt"]
            elif mutation == "wrong-field":
                actual[0][1]["temperature"] = 99
            elif mutation == "extra-field":
                actual[0][1]["kind"] = "speed"
            elif mutation == "missing-output":
                actual.pop()
            elif mutation == "duplicate-output":
                actual.append(actual[-1])
            elif mutation == "wrong-topic":
                actual[0] = ("matches", actual[0][1])
            else:
                topic, batch = actual[1]
                actual[1:2] = [(topic, record) for record in batch["records"]]
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                runtime.assert_deliveries(actual, self.expected)

    def test_malformed_outputs_and_nested_sentinels_fail(self):
        good = self.expected[0][1]
        malformed = [None, [], 42, "pending", {}, {"kind": "batch"},
                     {"kind": "batch", "records": None},
                     {"kind": "batch", "records": {}},
                     {"kind": "batch", "records": []},
                     {"kind": "batch", "records": [good]},
                     {"kind": "batch", "records": [good, None]},
                     {"kind": "batch", "records": [good, {"kind": "batch", "records": [good, good]}]},
                     {"kind": "batch", "records": [good, good], "unexpected": True}]
        for kind in runtime.INTERNAL_KINDS:
            sentinel = {"kind": kind}
            malformed.extend([sentinel, {"kind": "batch", "records": [good, sentinel]}])
        for value in malformed:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                runtime.validate_delivery("aligned", value)
        with self.assertRaises(AssertionError):
            runtime.validate_delivery("unknown", good)
        for topic in ("matches", "predictions-from-updates"):
            with self.subTest(topic=topic), self.assertRaises(AssertionError):
                runtime.validate_delivery(topic, {"kind": "batch", "records": [good, good]})


if __name__ == "__main__":
    unittest.main()
