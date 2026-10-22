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
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

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

    def test_sat_ticker_messages_match_rendered_full_topic_bindings(self):
        # Reuse the offline MQTT harness: no credentials, broker or paho needed.
        for name, path in (("ticker", BASE / "ticker" / "ticker.py"),
                           ("security_ticker_tests", BASE / "ticker" / "test_ticker.py")):
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
        harness = module.Harness(methodName="test_startup_register_and_ticks_contract")
        harness.setUp()
        try:
            harness.app.config = replace(harness.config, auth_mode="serviceAccountToken")
            Path(harness.config.token_file).write_text("synthetic-test-token\n")
            harness.app.connect()
            self.assertEqual(harness.app.client.auth, ("$sat", "synthetic-test-token"))
            harness.app.cycle()
            rendered = subprocess.run(
                ["helm", "template", "security-check", str(BASE / "chart"),
                 "--set-string", f"topicPrefix={harness.config.prefix}"],
                text=True, capture_output=True, check=True, timeout=30)
            bindings = {}
            for resource in yaml.safe_load_all(rendered.stdout):
                if resource["kind"] != "DataflowGraph":
                    continue
                for node in resource["spec"]["nodes"]:
                    for item in node.get("graphSettings", {}).get("configuration", []):
                        if item["key"] == "settings":
                            settings = json.loads(item["value"])
                            bindings.update({topic: kind for kind, topic in settings["inputTopics"].items()})
            for topic, payload, qos, retain in harness.app.client.messages:
                self.assertEqual(bindings[topic], payload["kind"])
                self.assertNotIn(payload["kind"], ("reading", "reset"))
                self.assertEqual((qos, retain), (1, False))
        finally:
            harness.app.close()
            harness.doCleanups()

    def test_mqtt_scenarios_against_actual_rust_core(self):
        for scenario in runtime.scenarios(BASE_TIME):
            with self.subTest(role=scenario.role):
                graph = yaml.safe_load((BASE / f"graph-{scenario.role}.yaml").read_text())
                configurations = {item["name"]: item["parameters"]
                                  for item in graph["moduleConfigurations"]}
                settings = json.loads(configurations["patterns"]["settings"]["default"])
                # Native Engine replay intentionally permits absent topic bindings.
                native_settings = {key: value for key, value in settings.items() if key != "inputTopics"}
                self.assertEqual(native_settings, scenario.configuration)
                self.assertNotIn("suppress-internal", configurations)
                operators = {op["operationType"]: op for op in graph["operations"]}
                repository = "azure-samples/explore-iot-operations/dataflow-patterns"
                version = graph["metadata"]["version"]
                self.assertEqual(operators["map"]["module"],
                                 f"{repository}/module-dataflow-patterns:{version}")
                self.assertEqual(operators["filter"]["module"],
                                 f"{repository}/module-dataflow-pattern-filter:{version}")
                self.assertEqual(operators["filter"]["name"], "suppress-internal")
                fixture = {"configuration": native_settings, "steps": [
                    {"topic": step.topic, "input": step.payload,
                     "nowMs": int(BASE_TIME.timestamp() * 1000) + (
                         step.elapsed_ms if step.elapsed_ms is not None else 10000 + index * 10)}
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

    def test_graph_defaults_have_complete_typed_topic_bindings(self):
        expected = {
            "report-by-exception": {"reading": "report-readings", "tick": "report-ticks"},
            "stable-alarm": {"reading": "alarm-readings", "tick": "alarm-ticks"},
            "offline-detection": {"reading": "availability-readings", "tick": "availability-ticks",
                                  "register": "availability-registers"},
            "running-total": {"reading": "total-readings", "reset": "total-resets"},
            "smooth-readings": {"reading": "smoothing-readings"},
        }
        for role, bindings in expected.items():
            with self.subTest(role=role):
                graph = yaml.safe_load((BASE / f"graph-{role}.yaml").read_text())
                module = graph["moduleConfigurations"][0]
                self.assertEqual(module["name"], "patterns")
                parameter = module["parameters"]["settings"]
                self.assertEqual(parameter["name"], "settings")
                settings = json.loads(parameter["default"])
                self.assertEqual(settings["role"], role)
                self.assertEqual(settings["inputTopics"],
                                 {kind: f"factory/{topic}" for kind, topic in bindings.items()})

    def test_offline_registration_uses_dedicated_source(self):
        scenario = next(item for item in runtime.reading_scenarios(BASE_TIME)
                        if item.role == "offline-detection")
        registers = [step for step in scenario.steps if step.payload["kind"] == "register"]
        self.assertEqual(len(registers), 2)
        self.assertTrue(all(step.topic == "availability-registers" for step in registers))

    def test_existing_fixtures_against_core_and_projection(self):
        for path in sorted((BASE / "fixtures").glob("*.json")):
            with self.subTest(fixture=path.name):
                fixture = json.loads(path.read_text())
                outputs = self.replay(fixture, f"fixture-{path.stem}")
                for step, core in zip(fixture["steps"], outputs):
                    self.assertEqual(graph_projection(fixture["configuration"]["role"], core),
                                     step["expected"])

    def test_sample_scenarios_with_full_topic_bindings_against_core(self):
        prefix = f"isolated/runtime-{uuid.uuid4().hex}"
        rendered = subprocess.run(
            ["helm", "template", "sample-replay", str(BASE / "chart"),
             "--set-string", f"topicPrefix={prefix}"],
            text=True, capture_output=True, check=True, timeout=30)
        deployed = {}
        for resource in yaml.safe_load_all(rendered.stdout):
            if resource["kind"] != "DataflowGraph":
                continue
            for node in resource["spec"]["nodes"]:
                for item in node.get("graphSettings", {}).get("configuration", []):
                    settings = json.loads(item["value"])
                    deployed[settings["role"]] = settings
        configured = runtime.sample_scenarios(BASE_TIME)[3:]
        self.assertEqual(len(configured), 5)
        expected_events = {
            "report-by-exception": ["initial", "heartbeat", "change"],
            "stable-alarm": ["active", "cleared"],
            "offline-detection": ["offline", "online"],
            "running-total": ["total", "totalReset", "total"],
            "smooth-readings": ["smoothed", "smoothed"],
        }
        for scenario in configured:
            with self.subTest(role=scenario.role):
                graph = yaml.safe_load((BASE / f"graph-{scenario.role}.yaml").read_text())
                defaults = json.loads(
                    graph["moduleConfigurations"][0]["parameters"]["settings"]["default"])
                bindings = {kind: f"{prefix}/{topic.removeprefix('factory/')}"
                            for kind, topic in defaults["inputTopics"].items()}
                settings = deployed[scenario.role]
                self.assertEqual(settings, dict(scenario.configuration, inputTopics=bindings))
                standalone = yaml.safe_load(
                    (BASE / "manifests" / f"{scenario.role}.yaml").read_text())
                processor = next(node for node in standalone["spec"]["nodes"]
                                 if "graphSettings" in node)
                standalone_settings = json.loads(
                    processor["graphSettings"]["configuration"][0]["value"])
                self.assertEqual(standalone_settings, dict(
                    settings, inputTopics=defaults["inputTopics"]))
                for step in scenario.steps:
                    self.assertEqual(bindings[step.payload["kind"]], f"{prefix}/{step.topic}")
                fixture = {"configuration": settings, "steps": [
                    {"input": step.payload, "topic": f"{prefix}/{step.topic}",
                     "nowMs": int(BASE_TIME.timestamp() * 1000) + step.elapsed_ms}
                    for step in scenario.steps]}
                outputs = self.replay(fixture, f"sample-{scenario.role}")
                actual, expected, events = [], [], []
                for index, (step, core) in enumerate(zip(scenario.steps, outputs)):
                    with self.subTest(step=index):
                        self.assertEqual(diagnostics(core), list(step.core_codes))
                        if step.expected is None and not step.core_codes:
                            self.assertEqual(core, {"kind": "pending"})
                        delivery = graph_projection(scenario.role, core)
                        self.assertEqual(delivery, step.expected)
                        if delivery is not None:
                            actual.append((scenario.destination, delivery))
                        if step.expected is not None:
                            expected.append((scenario.destination, step.expected))
                            events.append(step.expected.get(
                                "state", step.expected.get("reason", step.expected["kind"])))
                        runtime.assert_deliveries(actual, expected)
                self.assertEqual(events, expected_events[scenario.role])

    def test_alarm_gap_cancels_pending_persistence_and_tick_is_not_observation(self):
        reading = {"kind": "reading", "assetId": "gap-alarm",
                   "messageId": "r1", "sequence": 1, "value": 90}
        tick = {"kind": "tick", "assetId": "gap-alarm",
                "sampledAt": runtime.stamp(BASE_TIME)}
        origin = int(BASE_TIME.timestamp() * 1000)
        fixture = {"configuration": {"role": "stable-alarm", "raiseForMs": 1000,
                                     "maxObservationGapMs": 1500},
                   "steps": [{"input": value, "nowMs": origin + elapsed}
                             for elapsed, value in (
                                 (0, tick), (100, reading), (900, tick),
                                 (1700, tick), (1800, dict(reading, messageId="r2", sequence=2)),
                                 (2700, tick), (2800, tick), (5000, tick))]}
        outputs = self.replay(fixture, "alarm-gap")
        for index in (0, 1, 2, 3, 4, 5, 7):
            self.assertEqual(outputs[index], {"kind": "pending"})
        self.assertEqual(outputs[6], dict(
            reading, kind="alarm", messageId="r2", sequence=2, state="active",
            reason="thresholdSustained", threshold=80.0, emittedAtMs=origin + 2800,
            receivedAtMs=origin + 1800, observationAgeMs=1000, isFreshMeasurement=False))

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

    def test_sample_overrides_leave_graph_defaults_and_original_scenarios_unchanged(self):
        sample = runtime.sample_scenarios(BASE_TIME)
        self.assertEqual(sample[:3], self.scenarios[:3])
        configurations = {scenario.role: scenario.configuration for scenario in sample[3:]}
        self.assertEqual(configurations["report-by-exception"],
                         {"role": "report-by-exception", "heartbeatIntervalMs": 1000})
        self.assertEqual(configurations["stable-alarm"], {
            "role": "stable-alarm", "high": 80, "low": 70, "raiseForMs": 1000,
            "clearForMs": 500, "maxObservationGapMs": 1500})
        self.assertEqual(configurations["offline-detection"],
                         {"role": "offline-detection", "timeoutMs": 1000})
        self.assertEqual(sample[6].configuration, self.scenarios[6].configuration)
        self.assertEqual(sample[7].configuration, self.scenarios[7].configuration)
        self.assertEqual(self.scenarios, runtime.scenarios(BASE_TIME))

    def test_relative_step_gates_do_not_compress_after_late_publish(self):
        step = runtime.Step("alarm-ticks", {}, elapsed_ms=1350)
        # The reading intended for t=100ms was actually acknowledged at t=10s.
        with patch.object(runtime.time, "monotonic", return_value=10.05):
            self.assertAlmostEqual(runtime.step_delay(step, 100, 10), 1.2)
        with patch.object(runtime.time, "monotonic", return_value=12):
            self.assertEqual(runtime.step_delay(step, 100, 10), 0)
        step.elapsed_ms = 200
        with patch.object(runtime.time, "monotonic", return_value=10.05):
            self.assertAlmostEqual(runtime.step_delay(step, 100, 10), 0.05)

    def test_sample_alarm_ticks_have_persistence_and_observation_gap_margin(self):
        alarm = runtime.sample_scenarios(BASE_TIME)[4]
        reading = None
        for step in alarm.steps:
            if step.payload["kind"] == "reading":
                reading = step
            if step.expected is not None:
                age = step.elapsed_ms - reading.elapsed_ms
                duration = alarm.configuration[
                    "raiseForMs" if step.expected["state"] == "active" else "clearForMs"]
                self.assertEqual(age, duration + 250)
                self.assertLess(age, alarm.configuration["maxObservationGapMs"])
        self.assertTrue(all(step.wait == 0.05 for step in alarm.steps))

    def test_sample_unexpected_heartbeats_are_rejected(self):
        report = runtime.sample_scenarios(BASE_TIME)[3]
        expected = [(report.destination, step.expected) for step in report.steps
                    if step.expected is not None]
        origin = int(BASE_TIME.timestamp() * 1000)
        windows = {(report.destination, origin + step.elapsed_ms):
                   (origin + step.elapsed_ms, origin + step.elapsed_ms)
                   for step in report.steps}
        runtime.assert_live_deliveries(copy.deepcopy(expected), expected, windows)
        extra = copy.deepcopy(expected)
        extra.insert(2, copy.deepcopy(expected[1]))
        for check in (lambda: runtime.assert_deliveries(extra, expected),
                      lambda: runtime.assert_live_deliveries(extra, expected, windows)):
            with self.assertRaises(AssertionError):
                check()

    def test_live_clocks_are_bounded_bound_consistently_and_ages_checked(self):
        scenario = next(s for s in self.scenarios if s.role == "offline-detection")
        origin = int(BASE_TIME.timestamp() * 1000)
        expected = [(scenario.destination, step.expected) for step in scenario.steps
                    if step.expected is not None]
        windows = {(scenario.destination, origin + step.elapsed_ms):
                   (origin + step.elapsed_ms + 500, origin + step.elapsed_ms + 550)
                   for step in scenario.steps}
        actual = copy.deepcopy(expected)
        for _, value in actual:
            value["emittedAtMs"] += 500
            if value["lastSeenAtMs"] is not None:
                value["lastSeenAtMs"] += 500
        runtime.assert_live_deliveries(actual, expected, windows)
        for field in ("emittedAtMs", "elapsedMs", "lastSeenAtMs"):
            altered = copy.deepcopy(actual)
            altered[-1][1][field] += 10000
            with self.subTest(field=field), self.assertRaises(AssertionError):
                runtime.assert_live_deliveries(altered, expected, windows)
        report = next(s for s in self.scenarios if s.role == "report-by-exception")
        value = copy.deepcopy(report.steps[1].expected)
        expected_report = [("changes", copy.deepcopy(value))]
        report_windows = {("changes", value["emittedAtMs"]):
                          (value["emittedAtMs"], value["emittedAtMs"])}
        value["observationAgeMs"] = 1
        with self.assertRaises(AssertionError):
            runtime.assert_live_deliveries([("changes", value)], expected_report, report_windows)

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
