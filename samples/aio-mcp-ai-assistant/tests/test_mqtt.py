import asyncio
import ssl
from copy import deepcopy
from types import SimpleNamespace

import pytest

from aio_mcp_ai_assistant import mqtt
from aio_mcp_ai_assistant.common import SampleError, encode, loads
from aio_mcp_ai_assistant.config import Settings


class Messages:
    def __init__(self, items):
        self.items = iter(items)

    def __aiter__(self):
        return self

    async def __anext__(self):
        item = next(self.items, None)
        if item is not None:
            return item
        await asyncio.Event().wait()


def install_client(monkeypatch, tmp_path, items, *, rejected=False):
    calls = []
    token = tmp_path / "broker-token"
    token.write_text("test-broker-token")
    monkeypatch.setattr(mqtt, "BROKER_TOKEN", token)

    class Client:
        def __init__(self, **kwargs):
            calls.append(kwargs)
            self.messages = Messages(items)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_):
            return None

        async def subscribe(self, topic, *, qos):
            calls[-1].setdefault("subscriptions", []).append((topic, qos))
            return [135 if rejected else 1]

    monkeypatch.setattr(mqtt.aiomqtt, "Client", Client)
    return calls, token


def test_ignite_subscription_preserves_retained_delivery_and_refreshes_token(
    settings,
    monkeypatch,
    tmp_path,
):
    topic = settings.sources["person-detections"].topic
    messages = [
        SimpleNamespace(topic=topic, retain=True, payload=b'{"stale":true}'),
        SimpleNamespace(topic=topic, retain=False, payload=b'{"status":"ok","count":1}'),
    ]
    calls, token = install_client(monkeypatch, tmp_path, messages)
    tools = mqtt.MqttTools(settings, ssl.create_default_context())

    async def run():
        arguments = {"stage": "inference", "machine_id": "person", "max_messages": 1}
        result = await tools.call("mq_messages", arguments)
        assert result["count"] == 1
        assert result["messages"][0]["payload"] == {"stale": True}
        assert result["messages"][0]["receivedAt"].endswith("+00:00")
        assert result["topicFilter"] == topic
        assert result["timedOut"] is False
        token.write_text("rotated-test-broker-token")
        await tools.call("mq_messages", arguments)

    asyncio.run(run())
    assert calls[0]["properties"].AuthenticationMethod == "K8S-SAT"
    assert calls[1]["properties"].AuthenticationData == b"rotated-test-broker-token"
    assert calls[0]["subscriptions"] == [(topic, 1)]
    assert calls[0]["tls_context"].verify_mode == ssl.CERT_REQUIRED


def test_empty_window_is_explicit_not_a_zero_detection(settings, monkeypatch, tmp_path):
    install_client(monkeypatch, tmp_path, [])
    tools = mqtt.MqttTools(settings, ssl.create_default_context())
    result = asyncio.run(tools.call("mq_messages", {"stage": "inference", "timeout_ms": 100}))
    assert result["messages"] == []
    assert result["timedOut"] is True
    assert "personCount" not in result


def test_subscription_denial_is_not_an_empty_success(settings, monkeypatch, tmp_path):
    install_client(monkeypatch, tmp_path, [], rejected=True)
    tools = mqtt.MqttTools(settings, ssl.create_default_context())
    with pytest.raises(SampleError, match="rejected"):
        asyncio.run(tools.call("mq_messages", {"stage": "inference"}))


def test_stage_read_subscribes_only_to_its_configured_topics(config, monkeypatch, tmp_path):
    config["sources"]["gate-results"] = {
        "stage": "inference",
        "machineId": "safetygate",
        "topic": "edge/test/safetygate/results",
        "description": "Synthetic test fixture.",
    }
    settings = Settings.model_validate(config)
    topics = [settings.sources[name].topic for name in ("person-detections", "gate-results")]
    calls, _ = install_client(
        monkeypatch,
        tmp_path,
        [
            SimpleNamespace(topic=topic, retain=False, payload=b'{"synthetic":true}')
            for topic in topics
        ],
    )
    result = asyncio.run(
        mqtt.MqttTools(settings, ssl.create_default_context()).call(
            "mq_messages", {"stage": "inference", "max_messages": 2}
        )
    )
    assert calls[0]["subscriptions"] == [(topic, 1) for topic in topics]
    assert result["topicFilters"] == topics
    assert [item["topic"] for item in result["messages"]] == topics


@pytest.mark.parametrize("machine", ["person", "PERSON", "ignite-camera"])
def test_ignite_machine_selection(settings, monkeypatch, tmp_path, machine):
    topic = settings.sources["person-detections"].topic
    calls, _ = install_client(
        monkeypatch,
        tmp_path,
        [SimpleNamespace(topic=topic, retain=False, payload=b'{"synthetic":true}')],
    )
    asyncio.run(
        mqtt.MqttTools(settings, ssl.create_default_context()).call(
            "mq_messages", {"stage": "inference", "machine_id": machine, "max_messages": 1}
        )
    )
    assert calls[0]["subscriptions"] == [(topic, 1)]


def test_unconfigured_stage_is_rejected_before_connecting(settings, monkeypatch, tmp_path):
    calls, _ = install_client(monkeypatch, tmp_path, [])
    with pytest.raises(SampleError, match="No approved telemetry source"):
        asyncio.run(
            mqtt.MqttTools(settings, ssl.create_default_context()).call(
                "mq_messages", {"stage": "not-configured"}
            )
        )
    assert calls == []


@pytest.mark.parametrize(
    "payload",
    [
        b"not-json",
        '{"status":"ok"}'.encode("utf-16"),
        b"[]",
        b'{"value":NaN}',
        b'{"value":1,"value":2}',
        b"x" * (64 * 1024 + 1),
    ],
)
def test_invalid_observations_fail(payload):
    with pytest.raises(SampleError):
        mqtt.decode_message(payload)


def install_action_client(monkeypatch, tmp_path, settings, *, move_error=False, status="IDLE"):
    calls = []
    token = tmp_path / "action-token"
    token.write_text("test-token")
    monkeypatch.setattr(mqtt, "BROKER_TOKEN", token)

    class Client:
        def __init__(self, **kwargs):
            self.queue = asyncio.Queue()
            self.messages = self
            self.subscribed = False

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_):
            return None

        def __aiter__(self):
            return self

        async def __anext__(self):
            return await self.queue.get()

        async def subscribe(self, topic, *, qos):
            assert topic == settings.camera_response_topic
            self.subscribed = True
            return [1]

        async def publish_confirmed(self, topic, payload, *, properties=None):
            calls.append((topic, loads(payload), properties))
            if properties is None:
                return 42
            assert self.subscribed
            action = topic.rsplit("/", 1)[-1]
            response = {"Result": {}}
            if action == "ContinuousMove" and move_error:
                response = {"Error": {"message": "Simulated move failure"}}
            elif action == "GetStatus":
                response["Result"] = {
                    "PTZStatus": {
                        "MoveStatus": {"PanTilt": status},
                        "Position": {"PanTilt": {"x": 0.125}},
                    }
                }
            for retained, correlation in (
                (True, properties.CorrelationData),
                (False, b"wrong-correlation"),
                (False, properties.CorrelationData),
            ):
                await self.queue.put(
                    SimpleNamespace(
                        topic=properties.ResponseTopic,
                        retain=retained,
                        properties=SimpleNamespace(CorrelationData=correlation),
                        payload=encode(response).encode(),
                    )
                )
            return 42

    async def sleep(_):
        return None

    monkeypatch.setattr(mqtt, "AcknowledgedClient", Client)
    monkeypatch.setattr(mqtt.asyncio, "sleep", sleep)
    return calls


def test_camera_uses_correlated_move_stop_and_idle_status(action_settings, monkeypatch, tmp_path):
    calls = install_action_client(monkeypatch, tmp_path, action_settings)
    result = asyncio.run(
        mqtt.MqttTools(action_settings, ssl.create_default_context()).call(
            "mq_camera_pan", {"direction": "left", "duration_seconds": 1}
        )
    )
    assert [topic.rsplit("/", 1)[-1] for topic, _, _ in calls] == [
        "ContinuousMove",
        "Stop",
        "GetStatus",
    ]
    assert calls[0][1] == {
        "ContinuousMove": {
            "ProfileToken": "profile_high",
            "Velocity": {"PanTilt": {"x": -0.35, "y": 0.0}},
            "Timeout": "PT1S",
        }
    }
    assert len({properties.CorrelationData for _, _, properties in calls}) == 3
    assert result["stopConfirmed"] is True
    assert result["moveStatus"] == "IDLE"
    assert result["finalPan"] == 0.125


def test_camera_attempts_stop_after_a_failed_move(action_settings, monkeypatch, tmp_path):
    calls = install_action_client(monkeypatch, tmp_path, action_settings, move_error=True)
    with pytest.raises(SampleError, match="ONVIF error"):
        asyncio.run(
            mqtt.MqttTools(action_settings, ssl.create_default_context()).call(
                "mq_camera_pan", {"direction": "right"}
            )
        )
    assert [topic.rsplit("/", 1)[-1] for topic, _, _ in calls] == ["ContinuousMove", "Stop"]


def test_camera_does_not_report_success_without_idle(action_settings, monkeypatch, tmp_path):
    install_action_client(monkeypatch, tmp_path, action_settings, status="MOVING")
    with pytest.raises(SampleError, match="IDLE"):
        asyncio.run(
            mqtt.MqttTools(action_settings, ssl.create_default_context()).call(
                "mq_camera_pan", {"direction": "right"}
            )
        )


def test_publication_is_fixed_topic_and_deduplicated(
    action_settings, recommendation, monkeypatch, tmp_path
):
    calls = install_action_client(monkeypatch, tmp_path, action_settings)
    tools = mqtt.MqttTools(action_settings, ssl.create_default_context())

    async def run():
        result = await tools.call("mq_publish", recommendation)
        assert result["published"] is True
        assert result["qos"] == 1
        assert result["retain"] is False
        assert (await tools.call("mq_publish", recommendation))["duplicate"] is True
        conflicting = deepcopy(recommendation)
        conflicting["recommendation"]["summary"] = "Different recommendation"
        with pytest.raises(SampleError, match="different recommendation"):
            await tools.call("mq_publish", conflicting)

    asyncio.run(run())
    assert len(calls) == 1
    assert calls[0][:2] == (
        action_settings.recommendations.topic,
        {
            "idempotencyKey": recommendation["idempotency_key"],
            "recommendation": recommendation["recommendation"],
        },
    )


def test_sidecar_independently_rejects_disabled_actions(settings, recommendation):
    tools = mqtt.MqttTools(settings, ssl.create_default_context())

    async def run():
        for name, arguments in (
            ("mq_camera_pan", {"direction": "right"}),
            ("mq_publish", recommendation),
        ):
            with pytest.raises(SampleError, match="disabled"):
                await tools.call(name, arguments)

    asyncio.run(run())


def test_failed_publication_does_not_consume_the_idempotency_key(
    action_settings, recommendation, monkeypatch, tmp_path
):
    install_action_client(monkeypatch, tmp_path, action_settings)
    original = mqtt.AcknowledgedClient.publish_confirmed
    attempts = 0

    async def publish(client, *args, **kwargs):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise SampleError("Broker rejected the publication")
        return await original(client, *args, **kwargs)

    monkeypatch.setattr(mqtt.AcknowledgedClient, "publish_confirmed", publish)
    tools = mqtt.MqttTools(action_settings, ssl.create_default_context())

    async def run():
        with pytest.raises(SampleError, match="rejected"):
            await tools.call("mq_publish", recommendation)
        assert not tools.published
        assert (await tools.call("mq_publish", recommendation))["published"] is True

    asyncio.run(run())


@pytest.mark.parametrize("reason", [0, 16, 135])
def test_publish_checks_the_actual_mqtt5_puback(monkeypatch, reason):
    async def publish(client, topic, payload, **kwargs):
        assert kwargs["qos"] == 1 and kwargs["retain"] is False
        client._on_publish(
            None,
            None,
            7,
            mqtt.ReasonCode(mqtt.PacketTypes.PUBACK, identifier=reason),
            mqtt.Properties(mqtt.PacketTypes.PUBACK),
        )

    monkeypatch.setattr(mqtt.aiomqtt.Client, "publish", publish)

    async def run():
        client = mqtt.AcknowledgedClient(hostname="broker.example.test")
        if reason >= 128:
            with pytest.raises(SampleError, match="rejected"):
                await client.publish_confirmed("approved/topic", b"{}")
        else:
            assert await client.publish_confirmed("approved/topic", b"{}") == 7

    asyncio.run(run())
