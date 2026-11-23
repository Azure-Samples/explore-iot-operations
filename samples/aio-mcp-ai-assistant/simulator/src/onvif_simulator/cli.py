from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
from pathlib import Path

from pydantic import ValidationError

from onvif_simulator.app import Simulator
from onvif_simulator.config import load_settings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the ONVIF camera simulator")
    parser.add_argument(
        "--config",
        type=Path,
        help="YAML configuration file; environment variables override its values",
    )
    return parser


async def run(config_path: Path | None) -> None:
    settings = load_settings(config_path)
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    simulator = Simulator(settings)
    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()

    def request_stop() -> None:
        stopping.set()

    for signal_name in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(signal_name, request_stop)
        except NotImplementedError:
            signal.signal(signal_name, lambda *_: loop.call_soon_threadsafe(request_stop))

    await simulator.start()
    try:
        await stopping.wait()
    finally:
        await simulator.stop()


def main() -> None:
    args = build_parser().parse_args()
    try:
        asyncio.run(run(args.config))
    except (ValidationError, ValueError, RuntimeError, OSError) as exc:
        logging.getLogger(__name__).error("simulator startup failed: %s", exc)
        sys.exit(1)
