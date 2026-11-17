"""Run the inspection observer, submit events, and retrieve retained observations and evidence."""

import argparse
import json
import logging
import os
import queue
import signal
import sqlite3
import stat
import sys
import threading
import time
import uuid
from pathlib import Path

from collector import CapacityError, Collector, read_evidence, read_records
from inspection import (
    SCENARIO_NAMES,
    STAGES,
    JsonObject,
    encode,
    identifier,
    timestamp,
    utc,
    validate_scenarios,
)
from mqtt_transport import (
    BrokerSettings,
    Connection,
    TransportError,
    correlation,
    validate_trigger_time,
)

LOG = logging.getLogger(__name__)
READY_FILE = Path("/tmp/edge-inference-ready")
STOP = threading.Event()


def process_messages(
    connection: Connection, collector: Collector, routes: dict[str, tuple[str, str]]
) -> None:
    for _ in range(100):
        try:
            message = connection.inbox.get_nowait()
        except queue.Empty:
            break
        try:
            if message.retain:
                raise ValueError("Retained events are not supported; clear retained sample topics")
            if message.topic not in routes:
                raise ValueError(
                    "Topic is no longer configured; remove obsolete observer subscriptions"
                )
            scenario, stage = routes[message.topic]
            validation_error = None
            if stage == "trigger":
                try:
                    validate_trigger_time(message)
                except (ValueError, UnicodeDecodeError) as failure:
                    validation_error = str(failure)
            collector.ingest(
                scenario,
                stage,
                correlation(message),
                message.payload,
                validation_error=validation_error,
            )
        except ValueError as failure:
            LOG.error("Rejected event on %s: %s", message.topic, failure)
        connection.acknowledge(message)


def collect(
    args: argparse.Namespace, scenarios: list[JsonObject], settings: BrokerSettings
) -> None:
    routes = {
        f"{scenario['topicPrefix']}/{stage}": (scenario["name"], stage)
        for scenario in scenarios
        for stage in STAGES
    }
    by_name = {scenario["name"]: scenario for scenario in scenarios}
    collector = Collector(
        scenarios, args.state, args.media, args.responses, args.timeout, args.max_records
    )
    last_prune = 0
    try:
        while not STOP.is_set():
            connection = None
            try:
                connection = Connection(
                    settings, list(routes), "edge-inference-observer", persistent=True
                )
                READY_FILE.touch()
                checked_token = time.monotonic()
                while not STOP.is_set():
                    if connection.failed.is_set():
                        raise TransportError(connection.failure)
                    process_messages(connection, collector, routes)
                    collector.tick()
                    for item in collector.pending_publications():
                        if item["scenario"] not in by_name:
                            raise ValueError(
                                f"Unpublished inspection {item['id']} belongs to disabled scenario "
                                f"{item['scenario']}; restore that scenario and drain before updating"
                            )
                        topic = by_name[item["scenario"]]["topicPrefix"] + "/observations"
                        connection.publish(topic, item["observation"], item["id"])
                        collector.mark_published(item["id"])
                        print(item["observation"], flush=True)
                    now = time.monotonic()
                    if now - checked_token >= 15:
                        checked_token = now
                        if settings.token_file.read_bytes().strip() != connection.token:
                            LOG.info(
                                "Projected SAT rotated; reconnecting with the replacement token"
                            )
                            break
                    if now - last_prune >= 60:
                        collector.prune(args.retention_days)
                        last_prune = now
                    STOP.wait(0.2)
            except TransportError as failure:
                LOG.error("Broker unavailable: %s; retrying in five seconds", failure)
                STOP.wait(5)
            finally:
                READY_FILE.unlink(missing_ok=True)
                if connection is not None:
                    connection.close()
    finally:
        collector.close()


def trigger(args: argparse.Namespace, scenarios: list[JsonObject], settings: BrokerSettings) -> int:
    scenario = next((item for item in scenarios if item["name"] == args.scenario), None)
    if scenario is None:
        raise ValueError(f"Scenario is not enabled: {args.scenario}")
    requested_time = timestamp(args.event_time) if args.event_time else None
    context = json.loads(args.context)
    if not isinstance(context, dict):
        raise ValueError("--context must be a JSON object")
    inspection_id = str(uuid.uuid4())
    result_topic = scenario["topicPrefix"] + "/observations"
    connection = Connection(settings, [result_topic], f"edge-trigger-{inspection_id}")
    try:
        now = time.time()
        event_time = now - 2 if requested_time is None else requested_time
        if not now - 600 < event_time < now:
            raise ValueError(
                "Event time must be in the past and within the ten-minute snapshot buffer"
            )
        body = {
            "inspectionId": inspection_id,
            "assetId": scenario["assetName"],
            "eventTime": utc(event_time),
            "triggeredAt": utc(now),
            "context": context,
        }
        connection.publish(
            scenario["topicPrefix"] + "/trigger", encode(body), inspection_id, event_time
        )
        print(encode({"publishedInspectionId": inspection_id}), flush=True)
        deadline = time.monotonic() + args.wait_seconds
        while time.monotonic() < deadline and not STOP.is_set():
            if connection.failed.is_set():
                raise TransportError(connection.failure)
            try:
                message = connection.inbox.get(timeout=1)
            except queue.Empty:
                continue
            received_id = correlation(message)
            result = json.loads(message.payload)
            connection.acknowledge(message)
            if received_id == inspection_id:
                if not isinstance(result, dict) or result.get("inspectionId") != inspection_id:
                    raise ValueError("Observation body and trigger-id disagree")
                if result.get("status") not in ("REVIEW", "NO_FINDING", "ERROR"):
                    raise ValueError("Observation has an unsupported status")
                print(json.dumps(result, indent=2), flush=True)
                return 2 if result["status"] == "ERROR" else 0
        raise TransportError(
            f"No observation for {inspection_id}; inspect observer and graph health"
        )
    finally:
        connection.close()


def clean_responses(args: argparse.Namespace) -> None:
    cutoff = time.time() - args.older_than_hours * 3600
    removed = 0
    for path in args.responses.iterdir():
        try:
            identifier(path.name)
        except ValueError:
            LOG.warning("Leaving unrecognized response entry: %s", path.name)
            continue
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and info.st_mtime < cutoff:
            path.unlink()
            removed += 1
            if removed >= 1000:
                break
    LOG.info("Removed %d expired tensor files", removed)


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host",
        default=os.getenv("BROKER_HOST", "aio-broker.azure-iot-operations.svc.cluster.local"),
    )
    parser.add_argument("--port", type=positive_integer, default=18883)
    parser.add_argument("--ca-file", type=Path, default=Path("/var/run/certs/ca.crt"))
    parser.add_argument("--token-file", type=Path, default=Path("/var/run/tokens/token"))
    parser.add_argument("--scenarios", type=Path, default=Path("/app/config/scenarios.json"))
    commands = parser.add_subparsers(dest="command", required=True)

    observer = commands.add_parser(
        "collect", help="Persist inspection stages and publish observations"
    )
    observer.add_argument("--state", type=Path, default=Path("/state"))
    observer.add_argument("--media", type=Path, default=Path("/media"))
    observer.add_argument("--responses", type=Path, default=Path("/responses"))
    observer.add_argument("--timeout", type=positive_integer, default=180)
    observer.add_argument("--retention-days", type=positive_integer, default=7)
    observer.add_argument("--max-records", type=positive_integer, default=10000)

    sender = commands.add_parser("trigger", help="Submit one event and wait for its observation")
    sender.add_argument("--scenario", required=True, choices=SCENARIO_NAMES)
    sender.add_argument("--context", default="{}", help="Business context as a JSON object")
    sender.add_argument(
        "--event-time", help="ISO 8601 timestamp; defaults to two seconds before publication"
    )
    sender.add_argument("--wait-seconds", type=positive_integer, default=210)

    records = commands.add_parser("records", help="Read durable observations as JSON Lines")
    records.add_argument("--state", type=Path, default=Path("/state"))
    records.add_argument("--limit", type=positive_integer, default=20)
    selection = records.add_mutually_exclusive_group()
    selection.add_argument("--inspection-id", type=identifier)
    selection.add_argument(
        "--pending", action="store_true", help="List unfinished or unpublished inspections"
    )

    evidence = commands.add_parser(
        "evidence", help="Write a checksum-verified evidence JPEG to stdout"
    )
    evidence.add_argument("--state", type=Path, default=Path("/state"))
    evidence.add_argument("--inspection-id", type=identifier, required=True)

    cleanup = commands.add_parser("clean-responses", help="Remove expired UUID-named tensor files")
    cleanup.add_argument("--responses", type=Path, default=Path("/responses"))
    cleanup.add_argument("--older-than-hours", type=positive_integer, default=24)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    signal.signal(signal.SIGTERM, lambda signum, frame: STOP.set())
    signal.signal(signal.SIGINT, lambda signum, frame: STOP.set())
    try:
        if args.command == "clean-responses":
            clean_responses(args)
        elif args.command == "records":
            for record in read_records(args.state, args.inspection_id, args.limit, args.pending):
                print(encode(record))
        elif args.command == "evidence":
            sys.stdout.buffer.write(read_evidence(args.state, args.inspection_id))
        else:
            scenarios = json.loads(args.scenarios.read_text())
            validate_scenarios(scenarios)
            settings = BrokerSettings(args.host, args.port, args.ca_file, args.token_file)
            if args.command == "trigger":
                return trigger(args, scenarios, settings)
            collect(args, scenarios, settings)
    except (OSError, ValueError, sqlite3.Error, TransportError, CapacityError) as failure:
        LOG.error("%s", failure)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
