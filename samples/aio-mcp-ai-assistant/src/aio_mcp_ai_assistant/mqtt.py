import asyncio
import hashlib
import logging
import ssl
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import aiomqtt
import paho.mqtt.client as paho
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties
from paho.mqtt.reasoncodes import ReasonCode

from .common import JsonObject, SampleError, bounded_result, encode, loads, token_from
from .config import BROKER_TOKEN, Settings
from .tools import catalog, checked_tool

MAX_MESSAGE_BYTES = 64 * 1024
CAMERA_SPEED = 0.35
CAMERA_RPC_TIMEOUT = 20
LOGGER = logging.getLogger(__name__)


def decode_message(payload: bytes) -> JsonObject:
    if len(payload) > MAX_MESSAGE_BYTES:
        raise SampleError("MQTT message exceeds 64 KiB; select a bounded JSON observation topic")
    try:
        value = loads(payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise SampleError("MQTT source returned invalid JSON, not an observation") from error
    if not isinstance(value, dict):
        raise SampleError("MQTT source must publish JSON objects")
    return value


class AcknowledgedClient(aiomqtt.Client):
    last_puback: tuple[int, int] | None = None

    def _on_publish(
        self,
        client: paho.Client,
        userdata: object,
        mid: int,
        reason_code: ReasonCode,
        properties: Properties,
    ) -> None:
        # aiomqtt waits for PUBACK but otherwise discards its MQTT 5 reason code.
        self.last_puback = (mid, reason_code.value)
        super()._on_publish(client, userdata, mid, reason_code, properties)

    async def publish_confirmed(
        self, topic: str, payload: bytes, *, properties: Properties | None = None
    ) -> int:
        self.last_puback = None
        await self.publish(topic, payload, qos=1, retain=False, properties=properties, timeout=10)
        if self.last_puback is None:
            raise SampleError("MQTT publish did not receive a PUBACK")
        mid, reason = self.last_puback
        if reason >= 128:
            raise SampleError(f"Broker rejected the publication with MQTT reason {reason}")
        return mid


def camera_result(action: str, response: JsonObject) -> JsonObject:
    if response.get("Error") is not None:
        raise SampleError(
            f"Camera {action} returned an ONVIF error: {encode(response['Error'])[:500]}"
        )
    result = response.get("Result")
    if not isinstance(result, dict):
        raise SampleError(f"Camera {action} response did not contain Result")
    return result


class MqttTools:
    def __init__(self, settings: Settings, tls: ssl.SSLContext) -> None:
        self.settings = settings
        self.tls = tls
        self.lock = asyncio.Lock()
        self.published: dict[str, bytes] = {}
        self.tools = {
            tool.remote_name: tool for tool in catalog().values() if tool.source == "mqtt"
        }

    async def call(self, name: str, arguments: JsonObject) -> JsonObject:
        checked_tool(self.tools, name, arguments)
        if name == "mq_camera_pan" and not self.settings.camera.enabled:
            raise SampleError("Camera movement is disabled in this deployment")
        if name == "mq_publish" and not self.settings.recommendations.enabled:
            raise SampleError("Recommendation publishing is disabled in this deployment")
        if self.lock.locked():
            raise SampleError("Another MQTT operation is already active")
        async with self.lock:
            if name == "mq_camera_pan":
                return await self._pan(arguments)
            if name == "mq_publish":
                return await self._publish(arguments)
            return await self._sample(arguments)

    @asynccontextmanager
    async def _connection(self, *, publishing: bool = False):
        properties = Properties(PacketTypes.CONNECT)
        properties.AuthenticationMethod = "K8S-SAT"
        properties.AuthenticationData = (await token_from(BROKER_TOKEN)).encode()
        properties.MaximumPacketSize = 128 * 1024
        client_type = AcknowledgedClient if publishing else aiomqtt.Client
        async with client_type(
            hostname=self.settings.broker.host,
            port=self.settings.broker.port,
            protocol=aiomqtt.ProtocolVersion.V5,
            identifier=f"edge-assistant-{uuid.uuid4().hex}",
            properties=properties,
            tls_context=self.tls,
            timeout=10,
            max_queued_incoming_messages=32,
        ) as client:
            yield client

    async def _sample(self, arguments: JsonObject) -> JsonObject:
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
        count = arguments.get("max_messages", 5)
        seconds = arguments.get("timeout_ms", 3000) / 1000
        messages = []
        async with self._connection() as client:
            for topic in topics:
                reasons = await client.subscribe(topic, qos=1)
                if not reasons or any(
                    getattr(reason, "value", reason) >= 128 for reason in reasons
                ):
                    raise SampleError("Broker rejected the observation subscription")
            deadline = asyncio.get_running_loop().time() + seconds
            iterator = client.messages.__aiter__()
            while len(messages) < count:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    break
                try:
                    message = await asyncio.wait_for(anext(iterator), remaining)
                except asyncio.TimeoutError:
                    break
                topic = str(message.topic)
                if topic not in topics:
                    raise SampleError("Broker delivered a message outside the approved topics")
                messages.append(
                    {
                        "topic": topic,
                        "receivedAt": datetime.now(timezone.utc).isoformat(),
                        "payload": decode_message(bytes(message.payload)),
                    }
                )
                bounded_result({"messages": messages})
        return bounded_result(
            {
                **({"topicFilter": topics[0]} if len(topics) == 1 else {"topicFilters": topics}),
                "messages": messages,
                "count": len(messages),
                "timedOut": len(messages) < count,
            }
        )

    async def _publish(self, arguments: JsonObject) -> JsonObject:
        key = arguments["idempotency_key"]
        payload = encode(
            {"idempotencyKey": key, "recommendation": arguments["recommendation"]}
        ).encode()
        digest = hashlib.sha256(payload).digest()
        if key in self.published:
            if self.published[key] != digest:
                raise SampleError(
                    "The idempotency key was already used for a different recommendation"
                )
            return {"published": False, "duplicate": True, "idempotencyKey": key}
        if len(self.published) >= 1024:
            raise SampleError(
                "The 1024-key publication ledger is full; restarting clears deduplication history"
            )
        async with self._connection(publishing=True) as client:
            mid = await client.publish_confirmed(self.settings.recommendations.topic, payload)
            self.published[key] = digest
        return {
            "published": True,
            "topic": self.settings.recommendations.topic,
            "qos": 1,
            "retain": False,
            "messageId": mid,
            "idempotencyKey": key,
        }

    async def _camera_rpc(
        self, client: AcknowledgedClient, action: str, arguments: JsonObject
    ) -> JsonObject:
        correlation = uuid.uuid4().bytes
        properties = Properties(PacketTypes.PUBLISH)
        properties.ResponseTopic = self.settings.camera_response_topic
        properties.CorrelationData = correlation
        properties.MessageExpiryInterval = CAMERA_RPC_TIMEOUT
        await client.publish_confirmed(
            self.settings.camera.action_topic(action),
            encode({action: arguments}).encode(),
            properties=properties,
        )
        deadline = asyncio.get_running_loop().time() + CAMERA_RPC_TIMEOUT
        iterator = client.messages.__aiter__()
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise SampleError(f"Camera {action} response timed out")
            try:
                message = await asyncio.wait_for(anext(iterator), remaining)
            except asyncio.TimeoutError as error:
                raise SampleError(f"Camera {action} response timed out") from error
            if str(message.topic) != self.settings.camera_response_topic:
                raise SampleError("Broker delivered a message outside the camera reply topic")
            if (
                message.retain
                or getattr(message.properties, "CorrelationData", None) != correlation
            ):
                continue
            result = camera_result(action, decode_message(bytes(message.payload)))
            LOGGER.info("Camera %s completed through correlated MQTT RPC", action)
            return result

    async def _pan(self, arguments: JsonObject) -> JsonObject:
        direction = arguments["direction"]
        duration = arguments.get("duration_seconds", 2)
        profile = {"ProfileToken": self.settings.camera.profile_token}
        async with self._connection(publishing=True) as client:
            reasons = await client.subscribe(self.settings.camera_response_topic, qos=1)
            if not reasons or any(getattr(reason, "value", reason) >= 128 for reason in reasons):
                raise SampleError("Broker rejected the camera response subscription")
            try:
                await self._camera_rpc(
                    client,
                    "ContinuousMove",
                    {
                        **profile,
                        "Velocity": {
                            "PanTilt": {
                                "x": CAMERA_SPEED if direction == "right" else -CAMERA_SPEED,
                                "y": 0.0,
                            }
                        },
                        "Timeout": f"PT{duration}S",
                    },
                )
                await asyncio.sleep(duration)
            finally:
                await self._camera_rpc(client, "Stop", {**profile, "PanTilt": True, "Zoom": False})
            result = await self._camera_rpc(client, "GetStatus", profile)
        status = result.get("PTZStatus")
        if not isinstance(status, dict):
            raise SampleError("Camera GetStatus response did not contain PTZStatus")
        move = status.get("MoveStatus")
        if not isinstance(move, dict) or move.get("PanTilt") != "IDLE":
            raise SampleError("Camera GetStatus did not confirm an IDLE pan state")
        position = status.get("Position")
        pan_tilt = position.get("PanTilt") if isinstance(position, dict) else None
        pan = pan_tilt.get("x") if isinstance(pan_tilt, dict) else None
        if not isinstance(pan, (int, float)) or isinstance(pan, bool):
            raise SampleError("Camera GetStatus response did not contain a numeric pan position")
        return {
            "moved": True,
            "direction": direction,
            "speed": CAMERA_SPEED,
            "durationSeconds": duration,
            "stopConfirmed": True,
            "moveStatus": "IDLE",
            "finalPan": float(pan),
        }
