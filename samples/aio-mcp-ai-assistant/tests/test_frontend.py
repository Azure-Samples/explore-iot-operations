import asyncio
import base64
import json
import time
from copy import deepcopy

import pytest
from conftest import builtin_tools

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.frontend import (
    CAMERA_MOVE_FENCE,
    AioFrontend,
    decode_message,
    redact,
    verify_catalog,
)


class Client:
    def __init__(self, result=None):
        self.result = {} if result is None else result
        self.calls = []

    async def call_tool(self, name, arguments):
        self.calls.append((name, deepcopy(arguments)))
        return deepcopy(self.result)


def test_role_filtered_catalog_allows_extras_but_requires_enabled_publish(
    settings, action_settings
):
    tools = builtin_tools()
    tools.append({"name": "aio_delete_asset", "inputSchema": {"type": "object"}})
    verify_catalog(tools, action_settings)
    reader = [tool for tool in tools if tool["name"] != "aio_mqtt_publish"]
    verify_catalog(reader, settings)
    with pytest.raises(SampleError, match="aio_mqtt_publish"):
        verify_catalog(reader, action_settings)
    with pytest.raises(SampleError, match="duplicate"):
        verify_catalog(tools + [tools[0]], settings)


def test_catalog_resolves_local_object_schema_and_rejects_drift(action_settings):
    tools = builtin_tools()
    schema = tools[-1]["inputSchema"]
    schema["properties"]["payload"] = {"$ref": "#/$defs/Object"}
    schema["$defs"] = {"Object": {"type": "object"}}
    verify_catalog(tools, action_settings)
    schema["required"] = ["topic", "payload", "new_required_parameter"]
    with pytest.raises(SampleError, match="incompatible"):
        verify_catalog(tools, action_settings)
    schema["required"] = []
    schema["$defs"]["Object"] = {"$ref": "#/$defs/Object"}
    with pytest.raises(SampleError, match="reference"):
        verify_catalog(tools, action_settings)


def test_builtin_list_and_get_are_adapted_not_reimplemented(settings):
    client = Client({"motor": True, "camera-2": "Second camera", "camera-1": "First camera"})
    frontend = AioFrontend(settings, client)
    listed = asyncio.run(frontend.call_tool("list_assets", {"name_prefix": "camera", "limit": 1}))
    assert listed == {
        "items": [{"name": "camera-1", "description": "First camera"}],
        "count": 1,
        "truncated": True,
    }
    assert client.calls == [("aio_list_assets", {})]
    client.result = {
        "deviceRef": {"deviceName": "camera-1", "connectionString": "private-value"},
        "configuration": ' {"password":"private-value"}',
        "annotations": {"unfiltered": "private-value"},
    }
    got = asyncio.run(frontend.call_tool("get_asset", {"name": "camera-1"}))
    assert client.calls[-1] == ("aio_get_asset", {"asset": "camera-1"})
    assert "private-value" not in json.dumps(got)
    assert got["item"]["deviceRef"]["deviceName"] == "camera-1"
    with pytest.raises(SampleError):
        redact({"configuration": '{"secret": broken'})


@pytest.mark.parametrize("indicator", ["UTF8", "Unspecified"])
def test_decodes_utf8_and_binary_json_and_marks_sampling_time(settings, indicator):
    raw = json.dumps({"frameId": "synthetic-frame", "personCount": 1})
    encoded = base64.b64encode(raw.encode()).decode() if indicator == "Unspecified" else raw
    client = Client({"messages": [{"payload": encoded, "payload_format_indicator": indicator}]})
    result = asyncio.run(
        AioFrontend(settings, client).call_tool(
            "plant-telemetry", {"stage": "inference", "machine_id": "person", "max_messages": 1}
        )
    )
    message = result["messages"][0]
    assert message["payload"] == json.loads(raw)
    assert message["topic"] == settings.sources["person-detections"].topic
    assert "sampledAt" in message and "receivedAt" not in message
    assert client.calls[0][0] == "aio_mq_messages"
    assert client.calls[0][1]["topic"] == message["topic"]


@pytest.mark.parametrize(
    "message",
    [
        {},
        {"payload": "{}", "payload_format_indicator": "unknown"},
        {"payload": "!base64", "payload_format_indicator": "Unspecified"},
        {"payload": "[]", "payload_format_indicator": "UTF8"},
        {"payload": '{"x":1,"x":2}', "payload_format_indicator": "UTF8"},
        {"payload": '{"x":NaN}', "payload_format_indicator": "UTF8"},
        {"payload": "x" * (64 * 1024 + 1), "payload_format_indicator": "UTF8"},
    ],
)
def test_invalid_observations_are_not_silently_substituted(message):
    with pytest.raises(SampleError):
        decode_message(message)


def test_unconfigured_topic_fails_and_empty_window_is_explicit(settings):
    client = Client({"messages": []})
    frontend = AioFrontend(settings, client)
    with pytest.raises(SampleError, match="No approved"):
        asyncio.run(frontend.call_tool("plant-telemetry", {"stage": "arbitrary"}))
    assert not client.calls
    result = asyncio.run(frontend.call_tool("plant-telemetry", {"stage": "inference"}))
    assert result["messages"] == [] and result["timedOut"] is True


def test_approved_publication_is_fixed_nonretained_and_deduplicated(
    action_settings, recommendation
):
    client = Client()
    frontend = AioFrontend(action_settings, client)

    async def run():
        first = await frontend.call_tool("recommendation-publish", recommendation)
        assert first["published"] and first["qos"] == 1 and not first["retain"]
        assert (await frontend.call_tool("recommendation-publish", recommendation))["duplicate"]
        different = deepcopy(recommendation)
        different["recommendation"]["summary"] = "Another synthetic summary"
        with pytest.raises(SampleError, match="different payload"):
            await frontend.call_tool("recommendation-publish", different)

    asyncio.run(run())
    assert client.calls == [
        (
            "aio_mqtt_publish",
            {
                "topic": action_settings.recommendations.topic,
                "payload": {
                    "idempotencyKey": recommendation["idempotency_key"],
                    "recommendation": recommendation["recommendation"],
                },
            },
        )
    ]


def test_publishing_failure_does_not_record_success(action_settings, recommendation):
    class FailedClient(Client):
        async def call_tool(self, name, arguments):
            raise SampleError("Backend rejected publication")

    frontend = AioFrontend(action_settings, FailedClient())
    with pytest.raises(SampleError, match="rejected"):
        asyncio.run(frontend.call_tool("recommendation-publish", recommendation))
    assert not frontend.published


def idle(pan=0.2):
    return {"PTZStatus": {"MoveStatus": {"PanTilt": "IDLE"}, "Position": {"PanTilt": {"x": pan}}}}


def test_camera_correlates_native_graph_result_and_never_uses_direct_mqtt(
    action_settings, monkeypatch
):
    requests = []
    published = asyncio.Event()
    frontend = AioFrontend(action_settings, Client())
    original_sleep = asyncio.sleep

    async def sleep(_):
        await original_sleep(0)

    async def publish(topic, payload):
        requests.append((topic, deepcopy(payload)))
        published.set()

    async def sample(topic, maximum, timeout):
        await published.wait()
        request = requests[-1][1]
        return [
            {
                "payload": {
                    "type": "camera-action-result",
                    "requestId": request["requestId"],
                    "action": "GetStatus",
                    "assetName": action_settings.camera.asset_name,
                    "profileToken": action_settings.camera.profile_token,
                    "issuedAt": request["issuedAt"],
                    "completedAt": time.time(),
                    "error": None,
                    "response": {"Result": idle()},
                }
            }
        ]

    monkeypatch.setattr(asyncio, "sleep", sleep)
    monkeypatch.setattr(frontend, "_publish", publish)
    monkeypatch.setattr(frontend, "_sample", sample)
    result = asyncio.run(frontend.camera_status())
    assert result["stopConfirmed"]
    assert requests[0][0] == action_settings.camera.topic("requests", "GetStatus")
    assert requests[0][1]["payload"] == {"GetStatus": {"ProfileToken": "profile_high"}}
    assert type(requests[0][1]["issuedAt"]) is int


@pytest.mark.parametrize("failed_move", [False, True])
def test_pan_stops_and_verifies_idle_even_after_uncertain_move(
    action_settings, monkeypatch, failed_move
):
    frontend = AioFrontend(action_settings, Client())
    calls = []
    waits = []

    async def rpc(action, body):
        calls.append((action, body))
        if action == "ContinuousMove" and failed_move:
            raise SampleError("Uncertain move")
        return idle() if action == "GetStatus" else {}

    async def sleep(seconds):
        waits.append(seconds)

    monkeypatch.setattr(frontend, "_camera_rpc", rpc)
    monkeypatch.setattr(asyncio, "sleep", sleep)
    operation = frontend.call_tool("camera-pan", {"direction": "left", "duration_seconds": 1})
    if failed_move:
        with pytest.raises(SampleError, match="Uncertain"):
            asyncio.run(operation)
        assert CAMERA_MOVE_FENCE in waits
        assert [name for name, _ in calls] == [
            "GetStatus",
            "ContinuousMove",
            "Stop",
            "GetStatus",
            "Stop",
            "GetStatus",
        ]
    else:
        result = asyncio.run(operation)
        assert result["stopConfirmed"] and result["finalPan"] == 0.2
        assert [name for name, _ in calls] == ["GetStatus", "ContinuousMove", "Stop", "GetStatus"]
        assert calls[1][1]["Velocity"]["PanTilt"]["x"] == -0.35
        assert calls[1][1]["Timeout"] == "PT1S"
    assert frontend.motion_blocked is False


def test_lost_stop_latches_new_motion(action_settings, monkeypatch):
    frontend = AioFrontend(action_settings, Client())

    async def rpc(action, body):
        if action == "Stop":
            raise SampleError("Stop unavailable")
        return idle() if action == "GetStatus" else {}

    async def sleep(_):
        return None

    monkeypatch.setattr(frontend, "_camera_rpc", rpc)
    monkeypatch.setattr(asyncio, "sleep", sleep)

    async def run():
        with pytest.raises(SampleError, match="Stop unavailable"):
            await frontend.call_tool("camera-pan", {"direction": "right"})
        with pytest.raises(SampleError, match="unconfirmed"):
            await frontend.call_tool("camera-pan", {"direction": "right"})

    asyncio.run(run())
    assert frontend.motion_blocked


@pytest.mark.parametrize("cancel_action", ["ContinuousMove", "Stop"])
def test_cancelled_motion_is_stopped_and_verified_before_releasing_lock(
    action_settings, monkeypatch, cancel_action
):
    frontend = AioFrontend(action_settings, Client())
    calls = []
    waits = []
    cancelled = False

    async def rpc(action, body):
        nonlocal cancelled
        calls.append(action)
        if action == cancel_action and not cancelled:
            cancelled = True
            raise asyncio.CancelledError
        return idle() if action == "GetStatus" else {}

    async def sleep(seconds):
        waits.append(seconds)

    monkeypatch.setattr(frontend, "_camera_rpc", rpc)
    monkeypatch.setattr(asyncio, "sleep", sleep)
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(frontend.call_tool("camera-pan", {"direction": "right"}))
    assert calls.count("ContinuousMove") == 1
    assert calls[-2:] == ["Stop", "GetStatus"]
    assert CAMERA_MOVE_FENCE in waits
    assert not frontend.camera_lock.locked() and not frontend.motion_blocked


@pytest.mark.parametrize(
    "change",
    [
        {"action": "Stop"},
        {"assetName": "another-camera"},
        {"profileToken": "another-profile"},
        {"issuedAt": 0},
        {"completedAt": 0},
        {"error": "Native command failed"},
        {"response": {"Error": "ONVIF fault"}},
    ],
)
def test_correlated_camera_errors_never_report_success(action_settings, monkeypatch, change):
    frontend = AioFrontend(action_settings, Client())
    request = {"requestId": "request-1", "action": "GetStatus", "issuedAt": int(time.time())}
    frame = {
        "type": "camera-action-result",
        **request,
        "assetName": action_settings.camera.asset_name,
        "profileToken": action_settings.camera.profile_token,
        "completedAt": time.time(),
        "error": None,
        "response": {"Result": idle()},
        **change,
    }

    async def sample(*_):
        return [{"payload": frame}]

    monkeypatch.setattr(frontend, "_sample", sample)
    with pytest.raises(SampleError):
        asyncio.run(frontend._camera_response(request))


def test_camera_ignores_response_for_another_request(action_settings, monkeypatch):
    frontend = AioFrontend(action_settings, Client())
    request = {"requestId": "current", "action": "GetStatus", "issuedAt": int(time.time())}
    frame = {
        "type": "camera-action-result",
        **request,
        "assetName": action_settings.camera.asset_name,
        "profileToken": action_settings.camera.profile_token,
        "completedAt": time.time(),
        "error": None,
        "response": {"Result": idle()},
    }

    windows = iter([[{"payload": {"requestId": "another-request"}}], [{"payload": frame}]])

    async def sample(*_):
        return next(windows)

    monkeypatch.setattr(frontend, "_sample", sample)
    assert asyncio.run(frontend._camera_response(request)) == idle()
