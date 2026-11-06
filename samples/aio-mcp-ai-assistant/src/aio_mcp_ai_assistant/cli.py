import argparse
import json
import logging
import sys
from pathlib import Path

import httpx
import uvicorn

from .common import SampleError, loads
from .config import SETTINGS_PATH, load_settings
from .server import create_agent_app


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Built-in AIO MCP and Foundry Local operations assistant"
    )
    subcommands = parser.add_subparsers(dest="command", required=True)
    command = subcommands.add_parser("serve-agent")
    command.add_argument("--config", type=Path, default=SETTINGS_PATH)
    subcommands.add_parser("check")
    subcommands.add_parser("camera-check")
    ask = subcommands.add_parser("ask")
    ask.add_argument(
        "--stdin", action="store_true", required=True, help="Read a question from stdin"
    )
    tool = subcommands.add_parser("tool")
    tool.add_argument("name")
    tool.add_argument("arguments", help="JSON object matching the advertised tool schema")
    for decision in ("approve", "deny"):
        action = subcommands.add_parser(decision)
        action.add_argument("approval_id")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    try:
        if arguments.command == "serve-agent":
            settings = load_settings(arguments.config)
            uvicorn.run(
                create_agent_app(settings),
                host="127.0.0.1",
                port=8080,
                access_log=False,
                limit_concurrency=8,
            )
            return
        with httpx.Client(timeout=330, trust_env=False) as client:
            if arguments.command == "check":
                response = client.get("http://127.0.0.1:8080/readyz")
            elif arguments.command == "camera-check":
                response = client.get("http://127.0.0.1:8080/camera")
            elif arguments.command == "ask":
                question = sys.stdin.read(4001)
                if not question.strip() or len(question) > 4000:
                    raise ValueError("Provide a question of 1-4000 characters on stdin")
                response = client.post("http://127.0.0.1:8080/chat", json={"question": question})
            elif arguments.command in {"approve", "deny"}:
                response = client.post(
                    "http://127.0.0.1:8080/approval",
                    json={"id": arguments.approval_id, "decision": arguments.command},
                )
            else:
                values = loads(arguments.arguments)
                if not isinstance(values, dict):
                    raise ValueError("Tool arguments must be a JSON object")
                response = client.post(
                    "http://127.0.0.1:8080/tool",
                    json={"name": arguments.name, "arguments": values},
                )
            if response.status_code != 200:
                raise SampleError(
                    f"Assistant returned HTTP {response.status_code}: {response.text[:1000]}"
                )
            print(json.dumps(loads(response.content), indent=2, allow_nan=False))
    except (OSError, ValueError, SampleError, httpx.HTTPError) as error:
        parser.exit(1, f"Sample command failed: {error}\n")
