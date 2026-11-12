import asyncio
import base64
import binascii
import hashlib
import logging
import math
import re
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Protocol

from .common import JsonObject, SampleError, bounded_result, encode, loads
from .config import Settings
from .tools import catalog, checked_tool

LOGGER = logging.getLogger(__name__)
CAMERA_SPEED = 0.35
CAMERA_RPC_TIMEOUT = 20
CAMERA_MOVE_FENCE = 12
BUILTIN_SCHEMAS = {
    "aio_list_assets": {},
    "aio_get_asset": {"asset": "string"},
    "aio_list_devices": {},
    "aio_get_device": {"device": "string"},
    "aio_mq_messages": {"topic": "string", "timeout_ms": "integer", "max_messages": "integer"},
    "aio_mqtt_publish": {"topic": "string", "payload": "object"},
}
_SENSITIVE_KEYS = re.compile(
    r"(?:password|passwd|token|secret|credential|certificate|private.?key|api.?key|"
    r"connection.?string|^key$)",
    re.IGNORECASE,
)


class FrontendClient(Protocol):
    async def list_tools(self) -> list[JsonObject]: ...

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject: ...


def verify_catalog(advertised: list[JsonObject], settings: Settings) -> None:
    received = {}
    for tool in advertised:
        name = tool.get("name")
        if not isinstance(name, str) or name in received:
            raise SampleError("AIO MCP frontend advertised invalid or duplicate tool names")
        received[name] = tool.get("inputSchema")
    for name, parameters in BUILTIN_SCHEMAS.items():
        if name == "aio_mqtt_publish" and "Admin" not in settings.mcp_roles:
            continue
        if name not in received:
            raise SampleError(f"Built-in frontend is missing {name}; check its caller MCP roles")
        schema = received[name]
        if not isinstance(schema, dict) or schema.get("type") != "object":
            raise SampleError(f"Built-in frontend schema drift for {name}")
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if (
            not isinstance(properties, dict)
            or not isinstance(required, list)
            or any(not isinstance(field, str) for field in required)
            or set(required) - parameters.keys()
        ):
            raise SampleError(f"Built-in frontend has incompatible parameters for {name}")
        for field, expected_type in parameters.items():
            spec = properties.get(field)
            seen = set()
            while isinstance(spec, dict) and "$ref" in spec:
                ref = spec["$ref"]
                if (
                    not isinstance(ref, str)
                    or not ref.startswith("#/$defs/")
                    or ref in seen
                    or not isinstance(schema.get("$defs"), dict)
                ):
                    raise SampleError(f"Unsupported schema reference for {name}.{field}")
                seen.add(ref)
                spec = schema["$defs"].get(ref.removeprefix("#/$defs/"))
            if not isinstance(spec, dict) or spec.get("type") != expected_type:
                raise SampleError(f"Built-in frontend schema drift for {name}.{field}")


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if _SENSITIVE_KEYS.search(key) else redact(child)
            for key, child in value.items()
            if key != "annotations"
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, str):
        if value.lstrip().startswith(("{", "[")):
            try:
                nested = loads(value)
            except ValueError as error:
                raise SampleError("Resource contains invalid JSON configuration") from error
            return encode(redact(nested))
        if len(value) > 4096:
            raise SampleError("Resource string exceeds 4096 characters")
    return value


def decode_message(message: JsonObject) -> JsonObject:
    value = message.get("payload")
    indicator = message.get("payload_format_indicator")
    if not isinstance(value, str) or len(value) > 90 * 1024:
        raise SampleError("Built-in MQTT sampling returned a missing or oversized payload")
    try:
        if indicator == "Unspecified":
            raw = base64.b64decode(value, validate=True)
        elif indicator == "UTF8":
            raw = value.encode("utf-8")
        else:
            raise SampleError("Unknown MQTT payload format indicator")
        if len(raw) > 64 * 1024:
            raise SampleError("MQTT message exceeds 64 KiB")
        payload = loads(raw)
    except (ValueError, UnicodeDecodeError, binascii.Error) as error:
        raise SampleError("MQTT source returned invalid JSON/base64") from error
    if not isinstance(payload, dict):
        raise SampleError("MQTT source must publish JSON objects")
    return payload


class AioFrontend:
    """Application policy over the built-in frontend, not an MCP server."""

    def __init__(self, settings: Settings, client: FrontendClient) -> None:
        self.settings = settings
        self.client = client
        self.tools = catalog()
        self.publish_lock = asyncio.Lock()
        self.camera_lock = asyncio.Lock()
        self.motion_blocked = False
        self.published: dict[str, bytes] = {}

    async def list_tools(self) -> list[JsonObject]:
        return await self.client.list_tools()

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject:
        tool = checked_tool(self.tools, name, arguments)
        if name in {"list_assets", "list_devices"}:
            result = await self.client.call_tool(tool.remote_name, {})
            prefix = arguments.get("name_prefix", "")
            names = sorted(name for name in result if name.startswith(prefix))
            limit = arguments.get("limit", 20)
            items = [{"name": name, "description": redact(result[name])} for name in names[:limit]]
            return bounded_result(
                {"items": items, "count": len(items), "truncated": len(names) > limit}
            )
        if name in {"get_asset", "get_device"}:
            kind = "asset" if name == "get_asset" else "device"
            result = await self.client.call_tool(tool.remote_name, {kind: arguments["name"]})
            return bounded_result({"item": redact(result)})
        if name == "plant-telemetry":
            return await self._telemetry(arguments)
        if name == "camera-pan":
            if not self.settings.camera.enabled:
                raise SampleError("Camera movement is disabled in this deployment")
            return await self._pan(arguments)
        if not self.settings.recommendations.enabled:
            raise SampleError("Recommendation publishing is disabled in this deployment")
        return await self._recommendation(arguments)

    async def _sample(self, topic: str, maximum: int, timeout: int) -> list[JsonObject]:
        allowed = {source.topic for source in self.settings.sources.values()} | {
            self.settings.camera.topic("responses", action)
            for action in ("ContinuousMove", "Stop", "GetStatus")
        }
        if topic not in allowed:
            raise SampleError("Topic is outside the configured read policy")
        result = await self.client.call_tool(
            "aio_mq_messages",
            {"topic": topic, "max_messages": maximum, "timeout_ms": timeout},
        )
        messages = result.get("messages")
        if (
            not isinstance(messages, list)
            or len(messages) > maximum
            or any(not isinstance(message, dict) for message in messages)
        ):
            raise SampleError("Built-in MQTT sampling returned invalid messages")
        sampled_at = datetime.now(timezone.utc).isoformat()
        return [
            {"topic": topic, "sampledAt": sampled_at, "payload": decode_message(message)}
            for message in messages
        ]

    async def _telemetry(self, arguments: JsonObject) -> JsonObject:
        stage = arguments.get("stage")
        machine = arguments.get("machine_id")
        if machine is not None:
            machine = machine.lower()
        if stage == "inference" and machine == "ignite-camera":
            machine = "person"
        topics = [
            source.topic
            for source in self.settings.sources.values()
            if (source.stage != "inference" if stage is None else source.stage == stage)
            and (machine is None or source.machine_id == machine)
        ]
        if not topics:
            raise SampleError("No approved telemetry source matches stage/machine_id")
        maximum = arguments.get("max_messages", 5)
        groups = await asyncio.gather(
            *(self._sample(topic, maximum, arguments.get("timeout_ms", 3000)) for topic in topics)
        )
        messages = [message for group in groups for message in group][:maximum]
        return bounded_result(
            {
                **({"topicFilter": topics[0]} if len(topics) == 1 else {"topicFilters": topics}),
                "messages": messages,
                "count": len(messages),
                "timedOut": len(messages) < maximum,
            }
        )

    async def _publish(self, topic: str, payload: JsonObject) -> None:
        allowed = {self.settings.recommendations.topic} | {
            self.settings.camera.topic("requests", action)
            for action in ("ContinuousMove", "Stop", "GetStatus")
        }
        if topic not in allowed or len(encode(payload).encode()) > 64 * 1024:
            raise SampleError("Publication is outside the configured topic or payload policy")
        await self.client.call_tool("aio_mqtt_publish", {"topic": topic, "payload": payload})

    async def _recommendation(self, arguments: JsonObject) -> JsonObject:
        async with self.publish_lock:
            key = arguments["idempotency_key"]
            payload = {"idempotencyKey": key, "recommendation": arguments["recommendation"]}
            digest = hashlib.sha256(encode(payload).encode()).digest()
            if key in self.published:
                if self.published[key] != digest:
                    raise SampleError(
                        "The idempotency key was already used for a different payload"
                    )
                return {"published": False, "duplicate": True, "idempotencyKey": key}
            if len(self.published) >= 1024:
                raise SampleError("Publication ledger is full; reconcile before restarting")
            await self._publish(self.settings.recommendations.topic, payload)
            self.published[key] = digest
        return {
            "published": True,
            "topic": self.settings.recommendations.topic,
            "qos": 1,
            "retain": False,
            "idempotencyKey": key,
        }

    async def _camera_response(self, request: JsonObject) -> JsonObject:
        camera = self.settings.camera
        while True:
            messages = await self._sample(camera.topic("responses", request["action"]), 1, 5000)
            for message in messages:
                frame = message["payload"]
                if frame.get("requestId") != request["requestId"]:
                    continue
                issued, completed = frame.get("issuedAt"), frame.get("completedAt")
                if (
                    frame.get("type") != "camera-action-result"
                    or frame.get("action") != request["action"]
                    or frame.get("assetName") != camera.asset_name
                    or frame.get("profileToken") != camera.profile_token
                    or type(issued) not in (int, float)
                    or not math.isfinite(issued)
                    or issued != request.get("issuedAt")
                    or type(completed) not in (int, float)
                    or not math.isfinite(completed)
                    or not issued - 5 <= completed <= time.time() + 5
                    or time.time() - completed > CAMERA_RPC_TIMEOUT
                    or "error" not in frame
                ):
                    raise SampleError("Invalid or stale correlated ONVIF managed-action response")
                if frame["error"] is not None:
                    raise SampleError(
                        f"ONVIF managed action {request['action']} failed: {frame['error']}"
                    )
                response = frame.get("response")
                if (
                    not isinstance(response, dict)
                    or response.get("Error") is not None
                    or not isinstance(response.get("Result"), dict)
                ):
                    raise SampleError("ONVIF managed-action RPC failed or returned no Result")
                return response["Result"]

    async def _camera_rpc(self, action: str, body: JsonObject) -> JsonObject:
        async def invoke() -> JsonObject:
            request = {
                "requestId": uuid.uuid4().hex,
                "action": action,
                "payload": {action: body},
            }
            response = asyncio.create_task(self._camera_response(request))
            try:
                # The frontend does not expose a subscription-ready acknowledgement.
                await asyncio.sleep(2)
                if response.done():
                    return await response
                request["issuedAt"] = int(time.time())
                await self._publish(self.settings.camera.topic("requests", action), request)
                return await response
            finally:
                if not response.done():
                    response.cancel()
                await asyncio.gather(response, return_exceptions=True)

        try:
            return await asyncio.wait_for(invoke(), timeout=CAMERA_RPC_TIMEOUT)
        except asyncio.TimeoutError as error:
            raise SampleError(
                f"Camera {action} timed out; command delivery or execution may be unknown"
            ) from error

    async def camera_status(self) -> JsonObject:
        if self.settings.camera_graphs is None:
            raise SampleError("Configure and deploy cameraGraphs before checking camera status")
        result = await self._camera_rpc(
            "GetStatus", {"ProfileToken": self.settings.camera.profile_token}
        )
        status = result.get("PTZStatus")
        if not isinstance(status, dict):
            raise SampleError("Camera GetStatus did not contain PTZStatus")
        move = status.get("MoveStatus")
        position = status.get("Position")
        pan_tilt = position.get("PanTilt") if isinstance(position, dict) else None
        pan = pan_tilt.get("x") if isinstance(pan_tilt, dict) else None
        if (
            not isinstance(move, dict)
            or move.get("PanTilt") != "IDLE"
            or type(pan) not in (int, float)
            or not math.isfinite(pan)
            or not -1 <= pan <= 1
        ):
            raise SampleError("Camera GetStatus did not confirm IDLE and normalized pan position")
        return {"stopConfirmed": True, "moveStatus": "IDLE", "finalPan": float(pan)}

    async def _stop_and_status(self) -> JsonObject:
        await self._camera_rpc(
            "Stop",
            {"ProfileToken": self.settings.camera.profile_token, "PanTilt": True, "Zoom": False},
        )
        return await self.camera_status()

    async def _pan(self, arguments: JsonObject) -> JsonObject:
        if self.camera_lock.locked():
            raise SampleError("Another camera action is already active")
        if self.motion_blocked:
            raise SampleError(
                "Camera motion is unconfirmed; reconcile the camera and graph queues "
                "before restarting the agent"
            )
        async with self.camera_lock:
            await self.camera_status()
            duration = arguments.get("duration_seconds", 2)
            self.motion_blocked = True
            failure: BaseException | None = None
            try:
                await self._camera_rpc(
                    "ContinuousMove",
                    {
                        "ProfileToken": self.settings.camera.profile_token,
                        "Velocity": {
                            "PanTilt": {
                                "x": CAMERA_SPEED
                                if arguments["direction"] == "right"
                                else -CAMERA_SPEED,
                                "y": 0.0,
                            }
                        },
                        "Timeout": f"PT{duration}S",
                    },
                )
                await asyncio.sleep(duration)
            except (SampleError, asyncio.CancelledError) as error:
                failure = error
            try:
                status = await self._stop_and_status()
            except (SampleError, asyncio.CancelledError) as error:
                LOGGER.error("Initial camera Stop/IDLE verification failed: %s", error)
                failure = failure or error
            if failure is not None:
                # Cover graph input age (5s), future clock skew (5s), and RPC expiry (2s).
                await asyncio.sleep(CAMERA_MOVE_FENCE)
                await self._stop_and_status()
                self.motion_blocked = False
                raise failure
            self.motion_blocked = False
            return {
                "moved": True,
                "direction": arguments["direction"],
                "speed": CAMERA_SPEED,
                "durationSeconds": duration,
                **status,
            }
