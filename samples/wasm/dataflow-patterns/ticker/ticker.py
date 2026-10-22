"""Trusted, configured-assets-only MQTT clock companion.

Publishes QoS 1, non-retained processing-wall-clock ticks; never subscribes or
discovers assets. Idempotent availability registration is repeated each cycle
to recover a restarted graph's expected roster. The broker
must authorize this identity to publish only the selected input topics. PUBACK
confirms broker acceptance, not downstream processing. Keep host clocks synced.

Run ``python ticker.py --help`` for configuration and health probe semantics.
"""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import logging
import math
import os
from pathlib import Path
import signal
import ssl
import threading
import time


LOG = logging.getLogger("ticker")
ROLES = ("report", "alarm", "availability")


def boolean(value):
    if value not in ("true", "false"):
        raise ValueError("boolean settings must be true or false")
    return value == "true"


@dataclass(frozen=True)
class Config:
    host: str
    port: int
    tls: bool
    ca_file: str
    prefix: str
    assets: tuple
    roles: tuple
    interval: float
    auth_mode: str
    username: str
    password: str
    token_file: str
    health_file: str
    publish_timeout: float = 5.0
    connect_timeout: float = 5.0
    max_failures: int = 8

    @property
    def health_max_age(self):
        return max(30.0, 3 * self.interval + 2 * self.publish_timeout)

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        assets = json.loads(env.get("TICKER_ASSETS", "[]"))
        if (not isinstance(assets, list) or not assets
                or any(not isinstance(a, str) or not a.strip() for a in assets)
                or len(set(assets)) != len(assets)):
            raise ValueError("TICKER_ASSETS must be a nonempty JSON array of unique asset IDs")
        host = env.get("TICKER_MQTT_HOST", "").strip()
        prefix = env.get("TICKER_TOPIC_PREFIX", "").strip().rstrip("/")
        if not host or not prefix or any(c in prefix for c in ("+", "#", "\0")):
            raise ValueError("MQTT host and a literal topic prefix are required")
        interval = float(env.get("TICKER_INTERVAL_SECONDS", "1"))
        port = int(env.get("TICKER_MQTT_PORT", "8883"))
        if not math.isfinite(interval) or not 0.1 <= interval <= 60:
            raise ValueError("interval must be between 0.1 and 60 seconds")
        if not 1 <= port <= 65535:
            raise ValueError("invalid MQTT port")
        roles = tuple(r for r in ROLES if boolean(env.get("TICKER_TARGET_" + r.upper(), "true")))
        if not roles:
            raise ValueError("at least one tick target is required")
        mode = env.get("TICKER_AUTH_MODE", "serviceAccountToken")
        username = env.get("TICKER_USERNAME", "K8S-SAT")
        password = env.get("TICKER_PASSWORD", "")
        if mode not in ("serviceAccountToken", "existingSecret", "anonymous"):
            raise ValueError("invalid authentication mode")
        if mode == "existingSecret" and (not username or not password):
            raise ValueError("existingSecret requires username and password")
        if mode == "serviceAccountToken" and not username:
            raise ValueError("serviceAccountToken requires username")
        return cls(host, port, boolean(env.get("TICKER_TLS", "true")),
                   env.get("TICKER_CA_FILE", ""), prefix,
                   tuple(assets), roles, interval, mode, username, password,
                   env.get("TICKER_TOKEN_FILE", "/var/run/ticker-token/token"),
                   env.get("TICKER_HEALTH_FILE", "/health/puback"))


def healthy(path, max_age, clock=time.monotonic):
    try:
        stamp = float(Path(path).read_text(encoding="ascii"))
        age = clock() - stamp
        return math.isfinite(stamp) and 0 <= age <= max_age
    except (OSError, ValueError):
        return False


class Stopped(Exception):
    pass


class Companion:
    def __init__(self, config, mqtt, stop=None, clock=time.monotonic, wall=None):
        self.config = config
        self.mqtt = mqtt
        self.stop = stop if stop is not None else threading.Event()
        self.clock = clock
        self.wall = wall or (lambda: datetime.now(timezone.utc))
        self.connected = False
        self.rejected = False
        self.client = None
        self.last_ack = None

    def invalidate_health(self):
        Path(self.config.health_file).unlink(missing_ok=True)

    def on_connect(self, client, userdata, flags, reason_code, properties):
        self.connected = not reason_code.is_failure
        self.rejected = reason_code.is_failure

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        self.connected = False
        self.invalidate_health()

    def check_stop(self):
        if self.stop.is_set():
            raise Stopped()

    def pump_until(self, predicate, timeout):
        deadline = self.clock() + timeout
        while not predicate():
            self.check_stop()
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise TimeoutError("MQTT operation deadline exceeded")
            rc = self.client.loop(timeout=min(0.2, remaining))
            if rc != self.mqtt.MQTT_ERR_SUCCESS or self.rejected:
                raise ConnectionError("MQTT connection failed")
        self.check_stop()

    def connect(self):
        self.invalidate_health()
        self.connected = False
        self.rejected = False
        self.client = self.mqtt.Client(
            callback_api_version=self.mqtt.CallbackAPIVersion.VERSION2,
            protocol=self.mqtt.MQTTv311,
            reconnect_on_failure=False,
        )
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.connect_timeout = self.config.connect_timeout
        self.client.max_inflight_messages_set(1)
        self.client.max_queued_messages_set(1)
        if self.config.auth_mode != "anonymous":
            # Recreate the client and reread the projected token on EVERY attempt.
            password = self.config.password
            if self.config.auth_mode == "serviceAccountToken":
                password = Path(self.config.token_file).read_text(encoding="utf-8").strip()
                if not password:
                    raise ValueError("empty projected token")
            self.client.username_pw_set(self.config.username, password)
        if self.config.tls:
            self.client.tls_set_context(ssl.create_default_context(
                cafile=self.config.ca_file or None))
        # Paho 2.1.0 also uses keepalive as its TLS handshake socket timeout.
        # Five seconds each for TCP and TLS fits the pod's 15s stop grace.
        rc = self.client.connect(self.config.host, self.config.port, keepalive=5)
        if rc != self.mqtt.MQTT_ERR_SUCCESS:
            raise ConnectionError("MQTT connect failed")
        self.pump_until(lambda: self.connected, self.config.connect_timeout)

    def publish(self, suffix, asset, kind):
        self.check_stop()
        if not self.connected:
            raise ConnectionError("MQTT disconnected")
        payload = json.dumps({
            "assetId": asset,
            "kind": kind,
            "sampledAt": self.wall().isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        }, separators=(",", ":"))
        result = self.client.publish(
            self.config.prefix + "/" + suffix, payload, qos=1, retain=False)
        if result.rc != self.mqtt.MQTT_ERR_SUCCESS:
            raise ConnectionError("MQTT publish failed")
        self.pump_until(result.is_published, self.config.publish_timeout)
        if not self.connected:
            raise ConnectionError("MQTT disconnected before acknowledgement")
        # Only a real QoS-1 PUBACK can make the process ready.
        self.last_ack = self.clock()
        path = Path(self.config.health_file)
        pending = path.with_name(path.name + ".new")
        pending.write_text(str(self.last_ack), encoding="ascii")
        pending.replace(path)

    def cycle(self):
        for asset in self.config.assets:
            if "availability" in self.config.roles:
                self.publish("availability-registers", asset, "register")
            for role in self.config.roles:
                self.publish(role + "-ticks", asset, "tick")

    def idle(self, duration):
        deadline = self.clock() + duration
        while self.clock() < deadline:
            self.check_stop()
            if not self.connected:
                raise ConnectionError("MQTT disconnected")
            if self.last_ack is None or self.clock() - self.last_ack > self.config.health_max_age:
                raise TimeoutError("PUBACK watchdog expired")
            rc = self.client.loop(timeout=min(0.2, deadline - self.clock()))
            if rc != self.mqtt.MQTT_ERR_SUCCESS:
                raise ConnectionError("MQTT loop failed")

    def close(self):
        self.connected = False
        self.invalidate_health()
        if self.client is not None:
            try:
                self.client.disconnect()
            except (OSError, RuntimeError):
                pass
            self.client = None

    def run(self):
        failures = 0
        try:
            while not self.stop.is_set():
                try:
                    self.connect()
                    while not self.stop.is_set():
                        started = self.clock()
                        self.cycle()
                        # A CONNACK alone never resets a failing publisher's budget.
                        failures = 0
                        self.idle(max(0, self.config.interval - (self.clock() - started)))
                except Stopped:
                    break
                except (OSError, RuntimeError, ValueError):
                    self.close()
                    failures += 1
                    # Do not log exception strings: libraries can include credentials.
                    LOG.warning("MQTT attempt failed (%d/%d)", failures, self.config.max_failures)
                    if failures >= self.config.max_failures:
                        return 1
                    if self.stop.wait(min(30, 2 ** (failures - 1))):
                        break
        finally:
            self.close()
        return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Environment: TICKER_MQTT_HOST, TICKER_MQTT_PORT (8883), TICKER_TLS "
        "(true; system trust or TICKER_CA_FILE), TICKER_TOPIC_PREFIX, "
        "TICKER_ASSETS (JSON array), TICKER_INTERVAL_SECONDS (0.1..60), "
        "TICKER_TARGET_REPORT/ALARM/AVAILABILITY (true/false), TICKER_AUTH_MODE "
        "(serviceAccountToken/default, existingSecret, anonymous), TICKER_USERNAME "
        "(K8S-SAT), TICKER_PASSWORD, TICKER_TOKEN_FILE, TICKER_HEALTH_FILE. "
        "Token audience is configured by the projected Kubernetes volume. "
        "Health requires a recent real PUBACK; disconnect/shutdown removes health. "
        "Publish/CONNACK deadline 5s, eight consecutive failed attempts with "
        "1..30s exponential backoff; full acknowledged cycles reset retries."
    ))
    parser.add_argument("command", choices=("run", "healthcheck"), nargs="?", default="run")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_env()
        if args.command == "healthcheck":
            return 0 if healthy(config.health_file, config.health_max_age) else 1
        import paho.mqtt.client as mqtt
        stop = threading.Event()
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda signum, frame: stop.set())
        return Companion(config, mqtt, stop).run()
    except (OSError, ValueError, ImportError):
        LOG.error("Ticker configuration or initialization failed")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
