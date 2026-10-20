#!/usr/bin/env python3
"""Exercise deployed WASM graphs through their real MQTT endpoint.

Requires paho-mqtt==2.1.0, a fresh sample installation and MQTT_HOST/TOPIC_PREFIX.
Never runs a broker, installs an operator, or changes cluster credentials.
"""
import json
import os
import queue
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone


DESTINATIONS = ("aligned", "matches", "predictions-from-updates")
INTERNAL_KINDS = ("pending", "diagnostic", "modelApplied")


@dataclass
class Step:
    topic: str
    payload: dict
    expected: dict | None = None
    wait: float = 0
    core_codes: tuple = ()
    core_kind: str | None = None


@dataclass
class Scenario:
    role: str
    destination: str
    configuration: dict
    steps: list


def stamp(value):
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def scenarios(base):
    """Exact inputs/deliveries shared by MQTT and deterministic Rust replay.

    Zero-wait steps are sent together so a trusted event-time tick, rather than
    the processing-time fallback, drains multiple readings in one batch.
    core_codes/core_kind describe CLI-only results, never destination payloads.
    """
    at = lambda milliseconds: stamp(base + timedelta(milliseconds=milliseconds))
    align = []

    def alignment(asset, batch=False, mixed=False):
        context_at = at(1500 if mixed else 0)
        temperature = {"kind": "temperature", "assetId": asset,
                       "sampledAt": context_at, "temperature": 20}
        align.extend([
            Step("temperature", temperature),
            Step("temperature", temperature, core_codes=("duplicate",)),
            Step("temperature", dict(temperature, temperature=80), core_codes=("conflict",)),
            Step("temperature", dict(temperature, sampledAt=at(2000), temperature=99)),
        ])
        speeds = [{"kind": "speed", "assetId": asset, "sampledAt": at(1000), "speed": 12}]
        if batch:
            speeds[0].update(pieceId="batch-a", runId="runtime-run")
            speeds.append(dict(speeds[0], pieceId="batch-b", sampledAt=at(1500), speed=13))
        if mixed:
            speeds[0]["sampledAt"] = at(1600)
            speeds[1]["sampledAt"] = at(1800)
            align.append(Step("speed", {"kind": "speed", "assetId": asset,
                                       "sampledAt": at(1000), "speed": 90}))
        align.extend(Step("speed", speed, wait=0 if batch else 0.3) for speed in speeds)
        expected = []
        for speed in speeds:
            expected.append({key: value for key, value in speed.items() if key != "kind"} |
                            {"temperature": 20, "temperatureSampledAt": context_at})
        delivery = {"kind": "batch", "records": expected} if batch else expected[0]
        align.append(Step("speed", {"kind": "tick", "assetId": asset, "sampledAt": at(4000)},
                          delivery, wait=2, core_codes=("noContext",) if mixed else ()))
        for speed in speeds:
            align.extend([
                Step("speed", speed, core_codes=("duplicate",)),
                Step("speed", dict(speed, speed=999), core_codes=("conflict",)),
            ])
        align[-1].wait = 0.3

    alignment("runtime-align")
    alignment("runtime-batch", batch=True)
    alignment("runtime-mixed", batch=True, mixed=True)

    correlate = []
    for index, measurement_first in enumerate((True, False)):
        identity = {"assetId": "line-1", "pieceId": f"runtime-part-{index}",
                    "runId": "runtime-run"}
        prediction = dict(identity, kind="prediction", predictedAt=at(1000),
                          modelVersion=7, speed=10, temperature=20, speedCoefficient=2,
                          temperatureCoefficient=0.5, intercept=175, predictedWeight=205)
        measurement = dict(identity, kind="measurement", measuredAt=at(2000),
                           measuredWeight=200, targetWeight=198)
        first, second = (("measurements", measurement), ("predictions", prediction))
        if not measurement_first:
            first, second = second, first
        conflict_field = "measuredWeight" if measurement_first else "predictedWeight"
        matched = dict(prediction | measurement, kind="correlated", residual=-5, targetError=2)
        correlate.extend([
            Step(*first, wait=0.3),
            Step(*first, core_codes=("duplicate",)),
            Step(first[0], dict(first[1], **{conflict_field: 999}), core_codes=("conflict",)),
            Step(*second, expected=matched, wait=2),
            Step("predictions", prediction, core_codes=("duplicate",)),
            Step("measurements", measurement, core_codes=("duplicate",)),
            Step("predictions", dict(prediction, predictedWeight=999), core_codes=("conflict",)),
            Step("measurements", dict(measurement, measuredWeight=999),
                 wait=0.3, core_codes=("conflict",)),
        ])
    correlate.extend([
        Step("predictions", dict(prediction, assetId="other-asset", pieceId="isolated")),
        Step("measurements", dict(measurement, pieceId="isolated")),
        Step("predictions", dict(prediction, pieceId="isolated", runId="other-run"), wait=0.3),
    ])

    initial = {"assetId": "line-1", "modelVersion": 7, "speedCoefficient": 2,
               "temperatureCoefficient": 0.5, "intercept": 175}
    reading = {"kind": "reading", "assetId": "line-1", "pieceId": "runtime-v7",
               "runId": "runtime-run", "sampledAt": at(1000), "speed": 10, "temperature": 20}
    v7 = dict(reading | initial, kind="prediction", predictedWeight=205)
    model = dict(initial, kind="model", updateId="runtime-update-8",
                 expectedModelVersion=7, modelVersion=8, intercept=173)
    v8_reading = dict(reading, pieceId="runtime-v8")
    v8 = dict(v7, pieceId="runtime-v8", modelVersion=8, intercept=173, predictedWeight=203)
    predictor = [
        Step("readings", reading, v7, wait=2),
        Step("models", model, wait=0.3, core_kind="modelApplied"),
        Step("models", model, core_codes=("duplicateUpdate",)),
        Step("models", dict(model, intercept=999), core_codes=("conflictingUpdate",)),
        Step("models", dict(model, updateId="runtime-stale"), core_codes=("staleUpdate",)),
        Step("models", dict(model, updateId="runtime-gap", expectedModelVersion=8, modelVersion=10),
             core_codes=("versionConflict",), wait=0.3),
        Step("readings", v8_reading, v8, wait=2),
    ]
    return [
        Scenario("align-by-time", "aligned", {"role": "align-by-time"}, align),
        Scenario("correlate-by-id", "matches", {"role": "correlate-by-id"}, correlate),
        Scenario("versioned-predictor", "predictions-from-updates",
                 {"role": "versioned-predictor", "initialModels": [initial]}, predictor),
    ]


def validate_delivery(topic, value):
    """Reject malformed envelopes and internal records, including within batches."""
    if topic not in DESTINATIONS:
        raise AssertionError(f"Unexpected output topic: {topic}")
    if not isinstance(value, dict) or not value:
        raise AssertionError(f"Output must be a nonempty object: {value!r}")
    kind = value.get("kind")
    if kind in INTERNAL_KINDS:
        raise AssertionError(f"Internal output leaked: {value!r}")
    if kind == "batch":
        records = value.get("records")
        if (set(value) != {"kind", "records"} or not isinstance(records, list)
                or len(records) < 2 or topic == "predictions-from-updates"):
            raise AssertionError(f"Malformed/unexpected batch: {value!r}")
        for record in records:
            if isinstance(record, dict) and record.get("kind") == "batch":
                raise AssertionError(f"Nested batch: {record!r}")
            validate_delivery(topic, record)
    elif ((topic == "aligned" and "kind" in value)
          or (topic == "matches" and kind != "correlated")
          or (topic == "predictions-from-updates" and kind != "prediction")):
        raise AssertionError(f"Wrong output kind on {topic}: {value!r}")
    # Data shape and every field/value are checked against exact expectations.


def assert_deliveries(actual, expected):
    for topic, value in actual:
        validate_delivery(topic, value)
    if actual != expected:
        raise AssertionError(f"Exact deliveries differ:\nexpected={expected!r}\nactual={actual!r}")


def run():
    import paho.mqtt.client as mqtt

    host = os.environ["MQTT_HOST"]
    prefix = os.environ["TOPIC_PREFIX"].rstrip("/")
    if not prefix or any(char in prefix for char in "+#"):
        raise ValueError("TOPIC_PREFIX must be a concrete, isolated installation prefix")
    messages = queue.Queue()
    failures = queue.Queue()
    connected, subscribed = threading.Event(), threading.Event()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                         client_id=f"dataflow-test-{uuid.uuid4().hex[:16]}", clean_session=True)

    def on_connect(connection, userdata, flags, reason, properties):
        if reason.is_failure:
            failures.put(f"MQTT connection rejected: {reason}")
        else:
            connected.set()

    def on_subscribe(connection, userdata, mid, reasons, properties):
        if any(reason.is_failure for reason in reasons):
            failures.put(f"MQTT subscription rejected: {reasons}")
        else:
            subscribed.set()

    def on_message(connection, userdata, message):
        try:
            def reject_constant(value):
                raise ValueError(f"Non-finite JSON constant: {value}")
            messages.put((message.topic, json.loads(message.payload, parse_constant=reject_constant)))
        except (ValueError, UnicodeError) as error:
            failures.put(f"Non-JSON graph output: {error}")

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    if os.getenv("MQTT_USERNAME"):
        client.username_pw_set(os.environ["MQTT_USERNAME"], os.getenv("MQTT_PASSWORD"))
    if os.getenv("MQTT_TLS", "false").lower() == "true":
        client.tls_set(ca_certs=os.getenv("MQTT_CA_FILE"),
                       certfile=os.getenv("MQTT_CERT_FILE"), keyfile=os.getenv("MQTT_KEY_FILE"))
    client.connect(host, int(os.getenv("MQTT_PORT", "1883")), keepalive=30)
    client.loop_start()

    def healthy():
        if not failures.empty():
            raise AssertionError(failures.get_nowait())
        assert client.is_connected(), "MQTT connection lost"

    def publish(topic, payload):
        healthy()
        result = client.publish(f"{prefix}/{topic}", json.dumps(payload), qos=1, retain=False)
        result.wait_for_publish(timeout=10)
        assert result.is_published(), "MQTT publish not acknowledged"
        # Pace cross-topic arrivals; acknowledgement is not a graph-processing barrier.
        time.sleep(0.2)

    seen = []

    def receive(duration):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            healthy()
            try:
                topic, value = messages.get(timeout=min(0.2, max(0.001, deadline - time.monotonic())))
            except queue.Empty:
                continue
            destination = topic.removeprefix(f"{prefix}/")
            validate_delivery(destination, value)
            seen.append((destination, value))
        healthy()
        return seen

    try:
        assert connected.wait(15), "MQTT connect timed out"
        healthy()
        client.subscribe([(f"{prefix}/{topic}", 1) for topic in
                          DESTINATIONS])
        assert subscribed.wait(15), "MQTT subscribe timed out"
        receive(1)
        assert not seen, "Use a fresh isolated release with no retained outputs or other publishers"

        expected = []
        for scenario in scenarios(datetime.now(timezone.utc) - timedelta(seconds=10)):
            for step in scenario.steps:
                publish(step.topic, step.payload)
                if step.expected is not None:
                    expected.append((scenario.destination, step.expected))
                if step.wait:
                    receive(step.wait)
                    assert_deliveries(seen, expected)
        receive(3)
        assert_deliveries(seen, expected)
        print("PASS: exact real-MQTT payloads, tick/batch drain, both match orders, "
              "duplicates/conflicts, bootstrap v7/sequential v8, no internal outputs or feedback")
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    run()
