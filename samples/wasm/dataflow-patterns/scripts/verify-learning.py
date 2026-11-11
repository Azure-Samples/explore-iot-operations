#!/usr/bin/env python3
"""Real MQTT qualification of fresh fit/recommendation graphs with default settings."""
import json
import math
import os
import queue
import threading
import time
import uuid
from datetime import datetime, timezone


def run():
    import paho.mqtt.client as mqtt

    prefix = os.environ["TOPIC_PREFIX"].rstrip("/")
    if not prefix or any(c in prefix for c in "+#"):
        raise ValueError("Use a fresh literal topic prefix")
    received = queue.Queue()
    errors = queue.Queue()
    connected, subscribed = threading.Event(), threading.Event()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                         client_id="learning-test-" + uuid.uuid4().hex[:16])

    def on_connect(connection, userdata, flags, reason, properties):
        if reason.is_failure:
            errors.put(str(reason))
        else:
            connected.set()

    def on_subscribe(connection, userdata, mid, reasons, properties):
        if any(reason.is_failure for reason in reasons):
            errors.put(str(reasons))
        else:
            subscribed.set()

    def on_message(connection, userdata, message):
        try:
            received.put((message.topic.removeprefix(prefix + "/"),
                          json.loads(message.payload)))
        except (ValueError, UnicodeError) as error:
            errors.put(str(error))

    client.on_connect, client.on_subscribe, client.on_message = (
        on_connect, on_subscribe, on_message)
    if os.getenv("MQTT_USERNAME"):
        client.username_pw_set(os.environ["MQTT_USERNAME"], os.getenv("MQTT_PASSWORD"))
    if os.getenv("MQTT_TLS", "false").lower() == "true":
        client.tls_set(ca_certs=os.getenv("MQTT_CA_FILE"))
    client.connect(os.environ["MQTT_HOST"], int(os.getenv("MQTT_PORT", "1883")))
    client.loop_start()
    deliveries = []

    def healthy():
        assert errors.empty(), list(errors.queue)
        assert client.is_connected(), "MQTT connection lost"

    def publish(topic, payload):
        healthy()
        info = client.publish(prefix + "/" + topic, json.dumps(payload), qos=1, retain=False)
        info.wait_for_publish(10)
        assert info.is_published()

    def absent():
        time.sleep(1)
        healthy()
        assert received.empty(), "Unexpected delivery: " + repr(list(received.queue))

    def get(topic):
        actual_topic, value = received.get(timeout=30)
        healthy()
        assert actual_topic == topic, (actual_topic, value)
        deliveries.append(value)
        return value

    def stamp():
        return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

    try:
        assert connected.wait(15), "MQTT connect timeout"
        client.subscribe([(prefix + "/model-candidates", 1), (prefix + "/recommendations", 1)])
        assert subscribed.wait(15), "MQTT subscribe timeout"
        absent()
        points = [(-1, -1), (-1, 1), (1, -1), (1, 1), (2, 0), (0, 2)]
        run_id = uuid.uuid4().hex[:12]
        at = stamp()
        samples = [dict(kind="sample", assetId="fit-" + run_id, sampleId=f"s-{i}", epoch=1,
                        sequence=i, modelVersion=7, sampledAt=at, features=[x, z],
                        target=3*x-2*z+5) for i, (x, z) in enumerate(points, 1)]
        for sample in samples[:5]:
            publish("training-samples", sample)
        absent()
        publish("training-samples", samples[-1])
        fit = get("model-candidates")
        assert fit["kind"] == "modelCandidate" and fit["approved"] is False
        assert fit["sampleIds"] == [s["sampleId"] for s in samples]
        assert fit["sampleCount"] == 6 and fit["basisModelVersion"] == 7
        assert fit["epoch"] == 1 and fit["candidateId"] == "1:6"
        assert len(fit["coefficients"]) == 2
        for value, reference in zip(fit["coefficients"] + [fit["intercept"]], [3, -2, 5]):
            assert math.isclose(value, reference, abs_tol=1e-8)
        assert fit["rmse"] < 1e-8 and math.isclose(fit["rSquared"], 1, abs_tol=1e-8)
        publish("training-samples", samples[-1])
        publish("training-samples", dict(samples[-1], target=99))
        publish("training-samples", dict(samples[-1], sampleId="stale-sequence", sequence=1))
        publish("training-samples", dict(samples[-1], sampleId="false-approval",
                                         sequence=7, approved=True))
        # A separate asset's constant feature design must never produce a candidate.
        for i in range(1, 7):
            publish("training-samples", dict(samples[0], assetId="rank-" + run_id,
                                             sampleId=f"rank-{i}", sequence=i,
                                             features=[i, 1], target=i))
        absent()
        for i, (current, error, expected) in enumerate(
                [(5, 2, 4), (5, 100, 3), (0, 5, 0), (10, -5, 10)], 1):
            d = dict(kind="decision", assetId="decision-" + run_id, decisionId=f"d-{i}",
                     epoch=1, sequence=i, modelVersion=7, sampledAt=stamp(),
                     currentValue=current, error=error)
            publish("decision-inputs", d)
            out = get("recommendations")
            assert out["kind"] == "recommendation"
            assert out["recommendedValue"] == expected
            assert abs(out["delta"]) <= 2 and 0 <= expected <= 10
            assert out["approved"] is False and out["actuation"] is False
            publish("decision-inputs", d)
            publish("decision-inputs", dict(d, error=error+1))
            absent()
        for changes in (dict(modelVersion=8), dict(epoch=2), dict(approved=True),
                        dict(currentValue=11), dict(sampledAt="1970-01-01T00:00:01Z")):
            publish("decision-inputs", dict(d, decisionId="invalid", sequence=5, **changes))
        absent()
        print(json.dumps({"status": "PASS", "runtime": "real MQTT", "deliveries": deliveries}))
    finally:
        client.disconnect()
        client.loop_stop()


if __name__ == "__main__":
    run()
