import json
import queue
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import Mock

from collector import CapacityError
from inspection import utc
from mqtt_client import process_messages
from mqtt_transport import correlation, validate_trigger_time


class TriggerContractTests(unittest.TestCase):
    def message(self, properties):
        return SimpleNamespace(
            properties=SimpleNamespace(UserProperty=properties),
            payload=json.dumps({"eventTime": utc(1000)}).encode(),
        )

    def test_requires_unique_correlation_and_matching_event_clock(self):
        inspection_id = str(uuid.uuid4())
        valid = [("trigger-id", inspection_id), ("__ts", "000000001000000:00000:station")]
        message = self.message(valid)
        self.assertEqual(correlation(message), inspection_id)
        validate_trigger_time(message)
        for properties in (
            [],
            [("trigger-id", "not-a-uuid")],
            valid + [("trigger-id", inspection_id)],
        ):
            with self.subTest(properties=properties), self.assertRaises(ValueError):
                correlation(self.message(properties))
        for properties in (
            [("trigger-id", inspection_id)],
            valid + [("__ts", "000000001000000:00000:other")],
            [("trigger-id", inspection_id), ("__ts", "000000009000000:00000:station")],
        ):
            with self.subTest(properties=properties), self.assertRaises(ValueError):
                validate_trigger_time(self.message(properties))

    def test_capacity_failure_is_not_acknowledged_and_obsolete_topics_are_logged(self):
        message = self.message([("trigger-id", str(uuid.uuid4()))])
        message.topic = "sample/result"
        message.retain = False
        connection = SimpleNamespace(inbox=queue.Queue(), acknowledge=Mock())
        connection.inbox.put(message)
        collector = Mock()
        collector.ingest.side_effect = CapacityError("full")
        with self.assertRaises(CapacityError):
            process_messages(connection, collector, {"sample/result": ("equipment-area", "result")})
        connection.acknowledge.assert_not_called()
        connection.inbox.put(message)
        with self.assertLogs("mqtt_client", level="ERROR") as logs:
            process_messages(connection, collector, {})
        self.assertIn("no longer configured", logs.output[0])
        connection.acknowledge.assert_called_once_with(message)


if __name__ == "__main__":
    unittest.main()
