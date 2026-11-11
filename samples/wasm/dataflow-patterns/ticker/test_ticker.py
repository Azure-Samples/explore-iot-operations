"""Offline unittest suite: no installed paho, broker, or credentials required."""

from dataclasses import replace
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

import ticker


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


class Stop:
    def __init__(self, clock):
        self.clock = clock
        self.stopped = False
        self.waits = []

    def is_set(self):
        return self.stopped

    def set(self):
        self.stopped = True

    def wait(self, seconds):
        self.waits.append(seconds)
        self.clock.now += seconds
        return self.stopped


class FakeClient:
    def __init__(self, clock, **kwargs):
        self.clock = clock
        self.kwargs = kwargs
        self.auth = None
        self.context = None
        self.messages = []
        self.pending_connect = False
        self.pending_publish = None
        self.ack = True
        self.connack = True
        self.reject = False
        self.connect_rc = 0
        self.publish_rc = 0
        self.loop_rc = 0
        self.disconnects = 0

    def username_pw_set(self, username, password):
        self.auth = (username, password)

    def tls_set_context(self, context):
        self.context = context

    def max_inflight_messages_set(self, count):
        self.inflight = count

    def max_queued_messages_set(self, count):
        self.queued = count

    def connect(self, host, port, keepalive):
        self.address = (host, port, keepalive)
        self.pending_connect = True
        return self.connect_rc

    def loop(self, timeout):
        self.clock.now += timeout
        if self.pending_connect and self.connack:
            self.pending_connect = False
            self.on_connect(self, None, None, SimpleNamespace(is_failure=self.reject), None)
        if self.pending_publish and self.ack:
            self.pending_publish.done = True
        return self.loop_rc

    def publish(self, topic, payload, qos, retain):
        self.messages.append((topic, json.loads(payload), qos, retain))
        result = SimpleNamespace(rc=self.publish_rc, done=False)
        result.is_published = lambda: result.done
        self.pending_publish = result
        return result

    def disconnect(self):
        self.disconnects += 1
        self.on_disconnect(self, None, None, None, None)


class Harness(unittest.TestCase):
    def setUp(self):
        self.work = Path(__file__).parent / (".test-" + uuid.uuid4().hex)
        self.work.mkdir()
        self.addCleanup(shutil.rmtree, self.work)
        self.clock = Clock()
        self.stop = Stop(self.clock)
        self.env = {
            "TICKER_MQTT_HOST": "broker",
            "TICKER_TOPIC_PREFIX": "trusted/release",
            "TICKER_ASSETS": '["line-1", "line-2"]',
            "TICKER_TLS": "false",
            "TICKER_AUTH_MODE": "anonymous",
            "TICKER_TOKEN_FILE": str(self.work / "token"),
            "TICKER_HEALTH_FILE": str(self.work / "puback"),
        }
        self.config = ticker.Config.from_env(self.env)
        self.clients = []
        self.client_setup = lambda client: None

        def factory(**kwargs):
            client = FakeClient(self.clock, **kwargs)
            self.client_setup(client)
            self.clients.append(client)
            return client

        self.mqtt = SimpleNamespace(
            Client=factory, CallbackAPIVersion=SimpleNamespace(VERSION2=2),
            MQTTv311=4, MQTT_ERR_SUCCESS=0,
        )
        self.app = ticker.Companion(
            self.config, self.mqtt, self.stop, self.clock,
            lambda: datetime(2026, 10, 22, 0, 1, 2, 345678, timezone.utc),
        )

    def test_secure_configuration_defaults(self):
        env = {k: v for k, v in self.env.items() if k not in ("TICKER_AUTH_MODE", "TICKER_TLS")}
        config = ticker.Config.from_env(env)
        self.assertEqual((config.auth_mode, config.username, config.port, config.tls),
                         ("serviceAccountToken", "K8S-SAT", 8883, True))
        self.assertEqual(config.roles, ticker.ROLES)
        self.assertEqual(config.interval, 1)

    def test_invalid_assets(self):
        for assets in ("[]", "{}", '"asset"', '["a", "a"]', '[""]', '[" "]', '[1]', '["a", []]', "bad"):
            with self.subTest(assets=assets), self.assertRaises(ValueError):
                ticker.Config.from_env(dict(self.env, TICKER_ASSETS=assets))

    def test_invalid_intervals(self):
        for interval in ("0", "0.09", "61", "nan", "inf", "bad"):
            with self.subTest(interval=interval), self.assertRaises(ValueError):
                ticker.Config.from_env(dict(self.env, TICKER_INTERVAL_SECONDS=interval))

    def test_interval_boundaries(self):
        for interval in ("0.1", "60"):
            self.assertEqual(ticker.Config.from_env(
                dict(self.env, TICKER_INTERVAL_SECONDS=interval)).interval, float(interval))

    def test_invalid_host_prefix_port_boolean_and_mode(self):
        for key, value in (
            ("TICKER_MQTT_HOST", ""), ("TICKER_TOPIC_PREFIX", "/"),
            ("TICKER_TOPIC_PREFIX", "a/#"), ("TICKER_TOPIC_PREFIX", "a/+"),
            ("TICKER_TOPIC_PREFIX", "a\0"), ("TICKER_MQTT_PORT", "0"),
            ("TICKER_MQTT_PORT", "65536"), ("TICKER_TLS", "yes"),
            ("TICKER_TARGET_REPORT", "1"), ("TICKER_AUTH_MODE", "implicit"),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                ticker.Config.from_env(dict(self.env, **{key: value}))

    def test_no_targets_rejected(self):
        with self.assertRaises(ValueError):
            ticker.Config.from_env(dict(self.env, **{
                "TICKER_TARGET_" + r.upper(): "false" for r in ticker.ROLES}))

    def test_secret_auth_requires_both_fields(self):
        for username, password in (("", "secret"), ("user", ""), ("", "")):
            with self.subTest(username=username, password=password), self.assertRaises(ValueError):
                ticker.Config.from_env(dict(self.env, TICKER_AUTH_MODE="existingSecret",
                                            TICKER_USERNAME=username, TICKER_PASSWORD=password))

    def test_secret_auth(self):
        self.app.config = ticker.Config.from_env(dict(
            self.env, TICKER_AUTH_MODE="existingSecret",
            TICKER_USERNAME="user", TICKER_PASSWORD="secret"))
        self.app.connect()
        self.assertEqual(self.app.client.auth, ("user", "secret"))

    def test_anonymous_is_explicit_and_has_no_auth_call(self):
        self.app.connect()
        self.assertIsNone(self.app.client.auth)
        self.assertIsNone(self.app.client.context)
        self.assertEqual(self.app.client.kwargs,
                         {"callback_api_version": 2, "protocol": 4, "reconnect_on_failure": False})
        self.assertEqual((self.app.client.inflight, self.app.client.queued), (1, 1))
        self.assertEqual(self.app.client.connect_timeout, 5)
        self.assertEqual(self.app.client.address, ("broker", 8883, 5))

    def test_projected_token_rotation_on_reconnect(self):
        self.app.config = replace(self.config, auth_mode="serviceAccountToken")
        token = Path(self.config.token_file)
        token.write_text("token-one\n")
        self.app.connect()
        self.assertEqual(self.app.client.auth, ("K8S-SAT", "token-one"))
        self.app.close()
        token.write_text("token-two\n")
        self.app.connect()
        self.assertEqual(self.app.client.auth, ("K8S-SAT", "token-two"))
        self.assertEqual(len(self.clients), 2)

    def test_missing_or_empty_token_never_connects_anonymously(self):
        self.app.config = replace(self.config, auth_mode="serviceAccountToken")
        with self.assertRaises(OSError):
            self.app.connect()
        Path(self.config.token_file).write_text(" \n")
        with self.assertRaises(ValueError):
            self.app.connect()
        self.assertTrue(all(not c.pending_connect for c in self.clients))

    def test_tls_uses_verified_context_and_optional_ca(self):
        for ca in ("", "/mounted/ca.crt"):
            self.app.config = replace(self.config, tls=True, ca_file=ca)
            with patch.object(ticker.ssl, "create_default_context") as context:
                self.app.connect()
                context.assert_called_once_with(cafile=ca or None)
                self.assertIs(self.app.client.context, context.return_value)

    def test_invalid_ca_does_not_disable_tls(self):
        self.app.config = replace(self.config, tls=True, ca_file=str(self.work / "missing"))
        with self.assertRaises(OSError):
            self.app.connect()
        self.assertFalse(self.app.connected)

    def test_startup_register_and_ticks_contract(self):
        self.app.connect()
        self.app.cycle()
        messages = self.app.client.messages
        self.assertEqual(len(messages), 8)
        for i, asset in enumerate(self.config.assets):
            group = messages[i * 4:(i + 1) * 4]
            self.assertEqual([m[0] for m in group], [
                "trusted/release/availability-registers", "trusted/release/report-ticks",
                "trusted/release/alarm-ticks", "trusted/release/availability-ticks"])
            for j, (_, payload, qos, retain) in enumerate(group):
                self.assertEqual(payload, {
                    "assetId": asset, "kind": "register" if j == 0 else "tick",
                    "sampledAt": "2026-10-22T00:01:02.345Z"})
                self.assertEqual((qos, retain), (1, False))

    def test_registration_repeated_across_cycles_and_reconnect_for_graph_recovery(self):
        self.app.connect()
        self.app.cycle()
        self.app.cycle()
        self.assertEqual(len(self.app.client.messages), 16)
        self.app.close()
        self.app.connect()
        self.app.cycle()
        self.assertEqual(len(self.app.client.messages), 8)
        self.assertEqual(sum(m[1]["kind"] == "register" for m in self.app.client.messages), 2)
        self.assertTrue(all(m[0].endswith("/availability-registers")
                            for m in self.app.client.messages if m[1]["kind"] == "register"))

    def test_disabled_roles_do_not_publish_or_register(self):
        self.app.config = replace(self.config, roles=("alarm",))
        self.app.connect()
        self.app.cycle()
        self.assertEqual(len(self.app.client.messages), 2)
        self.assertTrue(all(m[0].endswith("/alarm-ticks") for m in self.app.client.messages))

    def test_unacknowledged_registration_retried(self):
        self.app.connect()
        self.app.client.ack = False
        with self.assertRaises(TimeoutError):
            self.app.cycle()
        self.app.close()
        self.app.connect()
        self.app.cycle()
        self.assertEqual(self.app.client.messages[0][1]["kind"], "register")

    def test_connect_alone_is_not_healthy_and_removes_stale_file(self):
        Path(self.config.health_file).write_text(str(self.clock()))
        self.app.connect()
        self.assertFalse(Path(self.config.health_file).exists())
        self.assertIsNone(self.app.last_ack)

    def test_ack_updates_health_atomically(self):
        self.app.connect()
        self.app.publish("report-ticks", "line-1", "tick")
        self.assertTrue(ticker.healthy(self.config.health_file, 30, self.clock))
        self.assertEqual(float(Path(self.config.health_file).read_text()), self.app.last_ack)
        self.assertFalse(Path(self.config.health_file + ".new").exists())

    def test_publish_error_has_no_fake_health(self):
        self.app.connect()
        self.app.client.publish_rc = 15
        with self.assertRaises(ConnectionError):
            self.app.publish("report-ticks", "a", "tick")
        self.assertFalse(Path(self.config.health_file).exists())

    def test_missing_puback_times_out_bounded(self):
        self.app.connect()
        self.app.client.ack = False
        started = self.clock()
        with self.assertRaises(TimeoutError):
            self.app.publish("report-ticks", "a", "tick")
        self.assertAlmostEqual(self.clock() - started, self.config.publish_timeout)
        self.assertIsNone(self.app.last_ack)

    def test_connack_timeout(self):
        self.client_setup = lambda c: setattr(c, "connack", False)
        with self.assertRaises(TimeoutError):
            self.app.connect()
        self.assertAlmostEqual(self.clock(), 100 + self.config.connect_timeout)

    def test_connack_rejection(self):
        self.client_setup = lambda c: setattr(c, "reject", True)
        with self.assertRaises(ConnectionError):
            self.app.connect()

    def test_connect_return_code_failure(self):
        self.client_setup = lambda c: setattr(c, "connect_rc", 1)
        with self.assertRaises(ConnectionError):
            self.app.connect()

    def test_loop_error_during_publish(self):
        self.app.connect()
        self.app.client.loop_rc = 7
        with self.assertRaises(ConnectionError):
            self.app.publish("report-ticks", "a", "tick")
        self.assertIsNone(self.app.last_ack)

    def test_disconnect_invalidates_health_and_prevents_publish(self):
        self.app.connect()
        self.app.cycle()
        self.app.client.disconnect()
        self.assertFalse(Path(self.config.health_file).exists())
        with self.assertRaises(ConnectionError):
            self.app.publish("report-ticks", "a", "tick")

    def test_health_rejects_missing_corrupt_stale_future_and_nonfinite(self):
        path = Path(self.config.health_file)
        self.assertFalse(ticker.healthy(path, 30, self.clock))
        for text in ("bad", "nan", "inf", "0", "101"):
            path.write_text(text)
            self.assertFalse(ticker.healthy(path, 30, self.clock), text)
        path.write_text("70")
        self.assertTrue(ticker.healthy(path, 30, self.clock))

    def test_idle_pumps_network(self):
        self.app.connect()
        self.app.cycle()
        started = self.clock()
        self.app.idle(1)
        self.assertAlmostEqual(self.clock() - started, 1)

    def test_watchdog_expires_without_recent_ack(self):
        self.app.connect()
        self.app.cycle()
        self.clock.now += self.config.health_max_age + 1
        with self.assertRaises(TimeoutError):
            self.app.idle(1)

    def test_idle_disconnect_and_loop_errors(self):
        self.app.connect()
        self.app.cycle()
        self.app.client.loop_rc = 7
        with self.assertRaises(ConnectionError):
            self.app.idle(1)
        self.app.connected = False
        with self.assertRaises(ConnectionError):
            self.app.idle(1)

    def test_bounded_exponential_retry_budget(self):
        self.client_setup = lambda c: setattr(c, "connect_rc", 1)
        with self.assertLogs("ticker", level="WARNING"):
            self.assertEqual(self.app.run(), 1)
        self.assertEqual(len(self.clients), 8)
        self.assertEqual(self.stop.waits, [1, 2, 4, 8, 16, 30, 30])
        self.assertTrue(all(c.disconnects == 1 for c in self.clients))
        self.assertFalse(Path(self.config.health_file).exists())

    def test_connack_without_successful_cycle_does_not_reset_retries(self):
        self.client_setup = lambda c: setattr(c, "publish_rc", 15)
        with self.assertLogs("ticker", level="WARNING"):
            self.assertEqual(self.app.run(), 1)
        self.assertEqual(len(self.clients), 8)
        self.assertTrue(all(c.messages[0][1]["kind"] == "register" for c in self.clients))

    def test_successful_cycle_resets_retry_budget(self):
        self.app.config = replace(self.config, max_failures=3)
        cycles = [ConnectionError("first"), None, ConnectionError("second"), None]

        def cycle():
            result = cycles.pop(0)
            if result:
                raise result
            if not cycles:
                self.stop.set()

        self.app.cycle = cycle
        self.app.idle = Mock(side_effect=[ConnectionError("after success"), ticker.Stopped()])
        with self.assertLogs("ticker", level="WARNING"):
            self.assertEqual(self.app.run(), 0)
        self.assertEqual(self.stop.waits, [1, 1, 2])

    def test_exception_text_is_never_logged(self):
        self.app.config = replace(self.config, max_failures=1)
        self.app.cycle = Mock(side_effect=ValueError("SECRET token payload asset"))
        with self.assertLogs("ticker", level="WARNING") as captured:
            self.assertEqual(self.app.run(), 1)
        self.assertNotIn("SECRET", "\n".join(captured.output))
        self.assertNotIn("payload", "\n".join(captured.output))

    def test_stop_during_wait_is_clean(self):
        self.app.connect()
        self.app.client.ack = False
        self.stop.set()
        with self.assertRaises(ticker.Stopped):
            self.app.publish("report-ticks", "a", "tick")
        self.assertFalse(self.app.client.messages)

    def test_stop_during_puback_wait_is_clean(self):
        self.app.connect()
        self.app.client.ack = False
        original_loop = self.app.client.loop

        def stopping_loop(timeout):
            self.stop.set()
            return original_loop(timeout)

        self.app.client.loop = stopping_loop
        with self.assertRaises(ticker.Stopped):
            self.app.publish("report-ticks", "a", "tick")
        self.assertIsNone(self.app.last_ack)
        self.assertFalse(Path(self.config.health_file).exists())

    def test_disconnect_even_with_ack_cannot_make_healthy(self):
        self.app.connect()
        original_loop = self.app.client.loop

        def disconnected_loop(timeout):
            result = original_loop(timeout)
            self.app.client.disconnect()
            return result

        self.app.client.loop = disconnected_loop
        with self.assertRaises(ConnectionError):
            self.app.publish("report-ticks", "a", "tick")
        self.assertIsNone(self.app.last_ack)
        self.assertFalse(Path(self.config.health_file).exists())

    def test_registration_repeats_all_assets_after_partial_cycle_failure(self):
        self.app.connect()
        original_publish = self.app.publish

        def publish(suffix, asset, kind):
            if asset == "line-2":
                raise ConnectionError("no ack")
            original_publish(suffix, asset, kind)

        self.app.publish = publish
        with self.assertRaises(ConnectionError):
            self.app.cycle()
        self.assertEqual(self.app.client.messages[0][1]["assetId"], "line-1")
        self.app.close()
        self.app.publish = original_publish
        self.app.connect()
        self.app.cycle()
        registrations = [m[1]["assetId"] for m in self.app.client.messages if m[1]["kind"] == "register"]
        self.assertEqual(registrations, ["line-1", "line-2"])

    def test_idle_without_any_ack_trips_watchdog(self):
        self.app.connect()
        with self.assertRaises(TimeoutError):
            self.app.idle(1)

    def test_shutdown_survives_disconnect_socket_error(self):
        self.app.connect()
        self.app.cycle()
        self.app.client.disconnect = Mock(side_effect=OSError("closed"))
        self.app.close()
        self.assertIsNone(self.app.client)
        self.assertFalse(Path(self.config.health_file).exists())

    def test_stop_during_backoff_is_clean(self):
        self.client_setup = lambda c: setattr(c, "connect_rc", 1)
        self.stop.wait = Mock(return_value=True)
        with self.assertLogs("ticker", level="WARNING"):
            self.assertEqual(self.app.run(), 0)
        self.assertEqual(len(self.clients), 1)

    def test_clean_shutdown_removes_health_and_disconnects(self):
        self.app.idle = lambda duration: self.stop.set()
        self.assertEqual(self.app.run(), 0)
        self.assertFalse(Path(self.config.health_file).exists())
        self.assertEqual(self.clients[0].disconnects, 1)
        self.assertIsNone(self.app.client)

    def test_healthcheck_command_needs_no_paho(self):
        with patch.dict(ticker.os.environ, self.env, clear=True):
            self.assertEqual(ticker.main(["healthcheck"]), 1)
            Path(self.config.health_file).write_text(str(ticker.time.monotonic()))
            self.assertEqual(ticker.main(["healthcheck"]), 0)

    def test_cli_invalid_config_redacts_errors(self):
        with patch.dict(ticker.os.environ, {}, clear=True), self.assertLogs("ticker") as captured:
            self.assertEqual(ticker.main([]), 1)
        self.assertEqual(len(captured.output), 1)


if __name__ == "__main__":
    unittest.main()
