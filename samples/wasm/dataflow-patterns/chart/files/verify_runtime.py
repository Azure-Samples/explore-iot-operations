#!/usr/bin/env python3
"""Exercise deployed WASM graphs through their real MQTT endpoint.

Requires paho-mqtt==2.1.0, a fresh sample installation and MQTT_HOST/TOPIC_PREFIX.
Disable the external ticker and all other publishers for this isolated run.
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


DESTINATIONS = ("aligned", "matches", "predictions-from-updates",
                "changes", "alarms", "availability", "totals", "smoothed")
INTERNAL_KINDS = ("pending", "diagnostic", "modelApplied")
SAMPLE_OVERRIDES = {
    "report-by-exception": {"heartbeatIntervalMs": 1000},
    "stable-alarm": {"high": 80, "low": 70, "raiseForMs": 1000,
                     "clearForMs": 500, "maxObservationGapMs": 1500},
    "offline-detection": {"timeoutMs": 1000},
}


@dataclass
class Step:
    topic: str
    payload: dict
    expected: dict | None = None
    wait: float = 0
    core_codes: tuple = ()
    core_kind: str | None = None
    elapsed_ms: int | None = None


@dataclass
class Scenario:
    role: str
    destination: str
    configuration: dict
    steps: list


def stamp(value):
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def scenarios(base, reading_overrides=None):
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
    ] + reading_scenarios(base, reading_overrides)


def sample_scenarios(base):
    """Chart/standalone demo settings, separate from graph-artifact defaults."""
    result = scenarios(base, SAMPLE_OVERRIDES)
    for scenario in result[3:]:
        # These two graphs have no tick source; their cold ticks are core-only.
        if scenario.role in ("running-total", "smooth-readings"):
            scenario.steps = [step for step in scenario.steps if step.payload["kind"] != "tick"]
        for step in scenario.steps:
            step.wait = 0.05
    return result


def reading_scenarios(base, overrides=None):
    """Processing-clock cases; sampledAt on ticks deliberately does not advance time."""
    overrides = overrides or {}
    origin = int(base.timestamp() * 1000)
    result = []
    for role, source, destination in (
            ("report-by-exception", "report", "changes"),
            ("stable-alarm", "alarm", "alarms"),
            ("offline-detection", "availability", "availability"),
            ("running-total", "total", "totals"),
            ("smooth-readings", "smoothing", "smoothed")):
        config = {"role": role}
        if role == "running-total":
            config["initialStates"] = [{"assetId": "sensor-1", "total": 0,
                                        "stateVersion": 0, "epoch": 0, "lastSequence": 0}]
        config.update(overrides.get(role, {}))
        steps = []
        asset = "sensor-1" if role == "running-total" else f"runtime-{source}"

        def add(kind, elapsed, expected=None, codes=(), **fields):
            payload = dict(kind=kind, assetId=asset, **fields)
            suffix = {"reset": "resets", "tick": "ticks", "register": "registers"}.get(kind, "readings")
            topic = f"{source}-{suffix}"
            steps.append(Step(topic, payload, expected, wait=0.5,
                              core_codes=codes, elapsed_ms=elapsed))
            return payload

        def observation(payload, kind, elapsed, received=None, **fields):
            value = dict(payload, kind=kind, emittedAtMs=origin + elapsed, **fields)
            if kind in ("reported", "alarm"):
                received = elapsed if received is None else received
                value.update(receivedAtMs=origin + received,
                             observationAgeMs=elapsed - received,
                             isFreshMeasurement=received == elapsed)
            return value

        tick = {"sampledAt": stamp(base)}
        add("tick", 0, **tick)  # Cold ticks must never initialize state.
        if role == "offline-detection":
            timeout = config.get("timeoutMs", 10000)
            add("register", 100)
            add("register", 200)
            add("tick", 300, **tick)
            offline = dict(kind="availability", assetId=asset, state="offline",
                           reason="timeout", emittedAtMs=origin + timeout + 1100,
                           lastSeenAtMs=None, elapsedMs=timeout + 1000)
            add("tick", timeout + 1100, offline, **tick)
            add("tick", timeout + 1200, **tick)
            online = dict(kind="availability", assetId=asset, state="online",
                          reason="recovered", emittedAtMs=origin + timeout + 1300,
                          lastSeenAtMs=origin + timeout + 1300, elapsedMs=timeout + 1200)
            add("reading", timeout + 1300, online, messageId="r1", sequence=1, value=10)
        elif role == "report-by-exception":
            reading = add("reading", 100, messageId="r1", sequence=1, value=10)
            steps[-1].expected = observation(reading, "reported", 100, reason="initial")
            add("reading", 200, codes=("duplicate",), messageId="r1", sequence=1, value=10)
            interval = config.get("heartbeatIntervalMs")
            elapsed = 100 + interval + 1000 if interval else 1200
            heartbeat = observation(reading, "reported", elapsed, received=100,
                                    reason="heartbeat") if interval else None
            add("tick", elapsed, heartbeat, **tick)
            reading = add("reading", elapsed + 100, messageId="r2", sequence=2, value=12)
            steps[-1].expected = observation(reading, "reported", elapsed + 100, reason="change")
        elif role == "stable-alarm":
            duration = config.get("raiseForMs", 0)
            reading = add("reading", 100, messageId="r1", sequence=1, value=80)
            if not duration:
                steps[-1].expected = observation(reading, "alarm", 100, state="active",
                                                reason="thresholdSustained", threshold=80.0)
            else:
                raised = 100 + duration + 250
                add("tick", raised, observation(
                    reading, "alarm", raised, received=100, state="active",
                    reason="thresholdSustained", threshold=80.0), **tick)
            gap = steps[-1].elapsed_ms + config.get("maxObservationGapMs", 5000) + 1000
            add("tick", gap, **tick)
            reading = add("reading", gap + 100, messageId="r2", sequence=2, value=70)
            clear = config.get("clearForMs", 0)
            if clear:
                cleared = gap + 100 + clear + 250
                add("tick", cleared, observation(
                    reading, "alarm", cleared, received=gap + 100,
                    state="cleared", reason="thresholdSustained", threshold=70.0), **tick)
            else:
                steps[-1].expected = observation(reading, "alarm", gap + 100,
                                                state="cleared", reason="thresholdSustained",
                                                threshold=70.0)
        elif role == "running-total":
            reading = add("reading", 100, messageId="r1", sequence=1, epoch=0, value=2.5)
            steps[-1].expected = observation(reading, "total", 100, total=2.5,
                                            stateVersion=1, lastSequence=1)
            add("reading", 200, codes=("duplicate",), messageId="r1", sequence=1, epoch=0, value=2.5)
            reset = add("reset", 300, resetId="reset-1", sequence=2, expectedStateVersion=1)
            steps[-1].expected = observation(reset, "totalReset", 300, total=0.0,
                                            epoch=1, stateVersion=2, lastSequence=2)
            add("reset", 400, codes=("duplicateReset",), resetId="reset-1",
                sequence=2, expectedStateVersion=1)
            add("reading", 500, codes=("epochConflict",),
                messageId="old", sequence=3, epoch=0, value=99)
            reading = add("reading", 600, messageId="r2", sequence=3, epoch=1, value=3)
            steps[-1].expected = observation(reading, "total", 600, total=3.0,
                                            stateVersion=3, lastSequence=3)
        else:
            alpha = config.get("alpha", 0.5)
            for index, value in enumerate((10, 12)):
                reading = add("reading", 100 + index * 100, messageId=f"r{index}",
                              sequence=index, value=value)
                steps[-1].expected = observation(reading, "smoothed", 100 + index * 100,
                                                smoothedValue=10 if not index else 10 + 2 * alpha)
            add("reading", 300, codes=("duplicate",), messageId="r1", sequence=1, value=12)
            add("reading", 400, codes=("conflict",), messageId="r1", sequence=2, value=99)
            add("reading", 500, codes=("staleReading",), messageId="old", sequence=0, value=99)
        result.append(Scenario(role, destination, config, steps))
    return result


def step_delay(step, previous_elapsed, last_publish):
    """Keep processing-clock intervals relative to the last acknowledged publish.

    A late step must not compress the next interval. Short settle waits count
    toward the gate, rather than accumulating on top of every 100ms step.
    """
    return max(0, last_publish + (step.elapsed_ms - previous_elapsed) / 1000
               - time.monotonic())


def await_delivery_count(receive, actual, expected, timeout=10):
    """Allow asynchronous graph delivery without changing inter-input timing."""
    deadline = time.monotonic() + timeout
    while len(actual) < len(expected):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        receive(min(0.2, remaining))


def publish_live_step(publish, step, flush_inputs=None):
    publish(step.topic, step.payload)
    if step.elapsed_ms is not None:
        # AIO can buffer a source record until the next arrival or idle flush.
        # An exact QoS-1 redelivery drains it promptly without refreshing a
        # reading's receipt clock or changing the configured processing gates.
        flush_inputs = {} if flush_inputs is None else flush_inputs
        source = step.topic.split("-")[0]
        key = (source, step.payload.get("assetId"))
        if step.payload["kind"] in ("reading", "register"):
            flush_inputs[key] = (step.topic, step.payload)
        flush = flush_inputs.get(key)
        if flush is not None:
            time.sleep(0.05)
            publish(*flush)


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
          or (topic == "predictions-from-updates" and kind != "prediction")
          or (topic in {"changes", "alarms", "availability", "totals", "smoothed"}
              and kind not in {"changes": ("reported",), "alarms": ("alarm",),
                               "availability": ("availability",), "totals": ("total", "totalReset"),
                               "smoothed": ("smoothed",)}[topic])):
        raise AssertionError(f"Wrong output kind on {topic}: {value!r}")
    # Data shape and every field/value are checked against exact expectations.


def assert_deliveries(actual, expected):
    for topic, value in actual:
        validate_delivery(topic, value)
    if actual != expected:
        raise AssertionError(f"Exact deliveries differ:\nexpected={expected!r}\nactual={actual!r}")


def assert_live_deliveries(actual, expected, windows):
    """Bind nondeterministic processing clocks, retaining exact payload comparisons.

    Hosts must be clock-synchronized within two seconds. Every timestamp must
    belong to its input's processing window; repeated references bind identically,
    and ages are checked arithmetically, never ignored or rounded.
    """
    bindings = {}
    last_reports = {}

    def canonical(topic, value, template):
        if not isinstance(value, dict) or not isinstance(template, dict):
            return value
        result = dict(value)
        if template.get("kind") == "batch" and isinstance(value.get("records"), list):
            result["records"] = [canonical(topic, record, wanted) for record, wanted
                                 in zip(value["records"], template["records"])]
            assert len(value["records"]) == len(template["records"])
            return result
        for field in ("emittedAtMs", "receivedAtMs", "lastSeenAtMs"):
            if field not in template or template[field] is None:
                continue
            clock = value.get(field)
            assert type(clock) is int, f"Invalid processing clock: {value!r}"
            key = (topic, template[field])
            lower, upper = windows[key]
            assert lower - 2000 <= clock <= upper + 2000, f"Clock outside publish window: {value!r}"
            assert bindings.setdefault(key, clock) == clock, f"Inconsistent clock reference: {value!r}"
            result[field] = template[field]
        if "observationAgeMs" in template:
            assert type(value.get("observationAgeMs")) is int and value["observationAgeMs"] >= 0
            assert value.get("observationAgeMs") == value["emittedAtMs"] - value["receivedAtMs"]
            assert value.get("isFreshMeasurement") == (value["observationAgeMs"] == 0)
            if topic == "alarms":
                duration = SAMPLE_OVERRIDES["stable-alarm"][
                    "raiseForMs" if value["state"] == "active" else "clearForMs"]
                assert duration <= value["observationAgeMs"] <= (
                    SAMPLE_OVERRIDES["stable-alarm"]["maxObservationGapMs"]), (
                        f"Alarm dwell/gap contract violated: {value!r}")
            if topic == "changes":
                asset = value["assetId"]
                if value["reason"] == "heartbeat":
                    assert value["emittedAtMs"] - last_reports[asset] >= (
                        SAMPLE_OVERRIDES["report-by-exception"]["heartbeatIntervalMs"])
                last_reports[asset] = value["emittedAtMs"]
            result["observationAgeMs"] = template["observationAgeMs"]
        if "elapsedMs" in template:
            reference = template["emittedAtMs"] - template["elapsedMs"]
            key = (topic, reference)
            elapsed = value.get("elapsedMs")
            assert type(elapsed) is int and elapsed >= 0
            clock = value["emittedAtMs"] - elapsed
            lower, upper = windows[key]
            assert lower - 2000 <= clock <= upper + 2000
            assert bindings.setdefault(key, clock) == clock
            result["elapsedMs"] = template["elapsedMs"]
            if value.get("state") == "offline":
                assert elapsed >= SAMPLE_OVERRIDES["offline-detection"]["timeoutMs"]
        return result

    assert len(actual) == len(expected), f"Delivery count differs: {actual!r} != {expected!r}"
    normalized = [(topic, canonical(topic, value, template))
                  for (topic, value), (_, template) in zip(actual, expected)]
    assert_deliveries(normalized, expected)


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

        expected, windows, flush_inputs = [], {}, {}
        base = datetime.now(timezone.utc) - timedelta(seconds=10)
        for scenario in sample_scenarios(base):
            previous_elapsed, last_publish = 0, time.monotonic()
            for step in scenario.steps:
                if step.elapsed_ms is not None:
                    delay = step_delay(step, previous_elapsed, last_publish)
                    if delay > 0:
                        receive(delay)
                before = int(time.time() * 1000)
                publish_live_step(publish, step, flush_inputs)
                if step.elapsed_ms is not None:
                    previous_elapsed, last_publish = step.elapsed_ms, time.monotonic()
                    windows[(scenario.destination, int(base.timestamp() * 1000) + step.elapsed_ms)] = (
                        before, int(time.time() * 1000))
                else:
                    # Preserve the original event-time scenarios' cross-topic pacing.
                    time.sleep(0.2)
                if step.expected is not None:
                    expected.append((scenario.destination, step.expected))
                if step.wait:
                    receive(step.wait)
                    if step.elapsed_ms is None:
                        assert_live_deliveries(seen, expected, windows)
                if step.elapsed_ms is not None and step.expected is not None:
                    # PUBACK acknowledges the broker, not the graph. Do not send
                    # the next phase's reading until this transition is observed.
                    await_delivery_count(receive, seen, expected)
                    delivered = int(time.time() * 1000)
                    for key, (lower, upper) in list(windows.items()):
                        if key[0] == scenario.destination:
                            windows[key] = (lower, max(upper, delivered))
                    assert_live_deliveries(seen, expected, windows)
            if previous_elapsed:
                # Short inter-input settles are not output-delivery deadlines.
                await_delivery_count(receive, seen, expected)
                assert_live_deliveries(seen, expected, windows)
        receive(3)
        assert_live_deliveries(seen, expected, windows)
        print("PASS: eight real-MQTT graph scenarios, exact payloads and processing-clock "
              "relationships, cold/gap ticks, resets, smoothing, no internal outputs")
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    run()
