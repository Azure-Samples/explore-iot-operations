"""MQTT 5 transport with TLS, projected SAT authentication, and manual acknowledgements."""

import json
import logging
import queue
import re
import threading
from dataclasses import dataclass
from pathlib import Path

import paho.mqtt.client as mqtt
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

from inspection import identifier, timestamp

LOG = logging.getLogger(__name__)


class TransportError(Exception):
    """A connection, subscription, publication, or acknowledgement failed."""


@dataclass(frozen=True)
class BrokerSettings:
    host: str
    port: int
    ca_file: Path
    token_file: Path


def correlation(message: mqtt.MQTTMessage) -> str:
    values = [
        value
        for key, value in getattr(message.properties, "UserProperty", [])
        if key == "trigger-id"
    ]
    if len(values) != 1:
        raise ValueError("Exactly one trigger-id MQTT user property is required")
    return identifier(values[0])


def validate_trigger_time(message: mqtt.MQTTMessage) -> None:
    values = [
        value for key, value in getattr(message.properties, "UserProperty", []) if key == "__ts"
    ]
    if len(values) != 1 or not re.fullmatch(r"\d{15}:\d{5}:.+", values[0]):
        raise ValueError("Trigger requires one __ts HLC user property")
    body = json.loads(message.payload)
    if (
        not isinstance(body, dict)
        or abs(timestamp(body.get("eventTime")) - int(values[0][:15]) / 1000) > 0.0011
    ):
        raise ValueError("Trigger eventTime and __ts disagree")


class Connection:
    """Own the network loop; leave durable processing and acknowledgement order to the caller."""

    def __init__(
        self,
        settings: BrokerSettings,
        topics: list[str],
        client_id: str,
        persistent: bool = False,
    ):
        self.topics = topics
        self.inbox: queue.Queue[mqtt.MQTTMessage] = queue.Queue(maxsize=100)
        self.ready = threading.Event()
        self.failed = threading.Event()
        self.failure = ""
        self.closing = False
        self.token = settings.token_file.read_bytes().strip()
        if not self.token:
            raise ValueError("Projected broker token is empty")
        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=client_id,
            protocol=mqtt.MQTTv5,
            manual_ack=True,
            reconnect_on_failure=False,
        )
        self.client.connect_timeout = 10
        self.client.tls_set(ca_certs=str(settings.ca_file))
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_subscribe = self._on_subscribe
        self.client.on_message = self._on_message
        properties = Properties(PacketTypes.CONNECT)
        properties.AuthenticationMethod = "K8S-SAT"
        properties.AuthenticationData = self.token
        properties.SessionExpiryInterval = 86400 if persistent else 0
        try:
            result = self.client.connect(
                settings.host,
                settings.port,
                keepalive=30,
                clean_start=not persistent,
                properties=properties,
            )
        except OSError as failure:
            raise TransportError(str(failure)) from failure
        if result != mqtt.MQTT_ERR_SUCCESS:
            raise TransportError(f"MQTT connect returned {result}")
        self.client.loop_start()
        if not self.ready.wait(15) or self.failed.is_set():
            self.close()
            raise TransportError(f"MQTT connection/subscriptions not ready: {self.failure}")

    def _fail(self, message: str) -> None:
        self.failure = message
        self.failed.set()
        self.ready.clear()
        LOG.error("%s", message)

    def _on_connect(self, client, userdata, flags, reason, properties):
        if reason.is_failure:
            self._fail(f"Broker rejected connection: {reason}")
            return
        if self.topics:
            result, _ = client.subscribe([(topic, 1) for topic in self.topics])
            if result != mqtt.MQTT_ERR_SUCCESS:
                self._fail(f"Subscribe returned {result}")
        else:
            self.ready.set()

    def _on_subscribe(self, client, userdata, mid, reasons, properties):
        if len(reasons) != len(self.topics) or any(
            reason.is_failure or reason.value != 1 for reason in reasons
        ):
            self._fail(f"Broker rejected subscriptions: {reasons}")
        else:
            self.ready.set()

    def _on_disconnect(self, client, userdata, flags, reason, properties):
        if not self.closing:
            self._fail(f"MQTT disconnected: {reason}")

    def _on_message(self, client, userdata, message):
        try:
            self.inbox.put_nowait(message)
        except queue.Full:
            self._fail("Inbound queue is full; disconnecting without acknowledging queued messages")
            client.disconnect()

    def publish(
        self,
        topic: str,
        payload: str,
        inspection_id: str,
        event_time: float | None = None,
    ) -> None:
        properties = Properties(PacketTypes.PUBLISH)
        properties.PayloadFormatIndicator = 1
        properties.ContentType = "application/json"
        properties.UserProperty = [("trigger-id", inspection_id)]
        if event_time is not None:
            properties.UserProperty.append(
                ("__ts", f"{int(event_time * 1000):015d}:00000:edge-inspection")
            )
        info = self.client.publish(topic, payload, qos=1, retain=False, properties=properties)
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            raise TransportError(f"Publish returned {info.rc}")
        try:
            info.wait_for_publish(timeout=15)
            if not info.is_published():
                raise TransportError("Timed out waiting for broker PUBACK")
        except RuntimeError as failure:
            raise TransportError(str(failure)) from failure

    def acknowledge(self, message: mqtt.MQTTMessage) -> None:
        result = self.client.ack(message.mid, message.qos)
        if result != mqtt.MQTT_ERR_SUCCESS:
            raise TransportError(f"MQTT acknowledgement returned {result}")

    def close(self) -> None:
        self.closing = True
        self.client.disconnect()
        self.client.loop_stop()
