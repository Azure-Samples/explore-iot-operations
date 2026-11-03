import argparse
import subprocess
import sys
from pathlib import Path

from aio_mcp_ai_assistant.common import SampleError, loads
from aio_mcp_ai_assistant.config import load_settings
from aio_mcp_ai_assistant.deployment import Deployment, render, write_manifests

ROOT = Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build, deploy, and use the MCP operations sample."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for command in (
        "render",
        "build",
        "push",
        "prepare",
        "model",
        "workloads",
        "simulator",
        "status",
        "check",
        "ask",
        "tool",
        "approve",
        "deny",
        "cleanup",
    ):
        child = commands.add_parser(command)
        child.add_argument("config", type=Path, help="Path to the populated JSON configuration")
        if command == "ask":
            child.add_argument("question", help="An independent operations question")
        elif command == "tool":
            child.add_argument("name")
            child.add_argument("arguments", help="A JSON object matching the tool's input schema")
        elif command in {"approve", "deny"}:
            child.add_argument("approval_id")
        elif command == "cleanup":
            child.add_argument(
                "--yes", action="store_true", help="Confirm explicit resource deletion"
            )
    arguments = parser.parse_args()
    if arguments.command == "cleanup" and not arguments.yes:
        parser.error("cleanup requires --yes; it deletes the sample's explicit resources")
    try:
        settings = load_settings(arguments.config)
        manifests = render(settings, ROOT / "kubernetes")
        deployment = Deployment(settings, manifests)
        if arguments.command == "render":
            write_manifests(settings, manifests, ROOT / ".generated")
            print("Wrote .generated/*.yaml and broker-rule.json. No cluster changes made.")
        elif arguments.command in {"build", "push"}:
            if arguments.command == "build":
                if "@sha256:" in settings.image:
                    raise SampleError("Build with a version tag, not a digest image reference")
                subprocess.run(
                    [
                        "docker",
                        "build",
                        "--platform=linux/amd64",
                        "--tag",
                        settings.image,
                        str(ROOT),
                    ],
                    check=True,
                )
            else:
                subprocess.run(["docker", "push", settings.image], check=True)
        elif arguments.command == "check":
            deployment.client("check")
        elif arguments.command == "ask":
            if not arguments.question.strip() or len(arguments.question) > 4000:
                raise ValueError("question must contain 1-4000 characters")
            deployment.client("ask", "--stdin", stdin=arguments.question)
        elif arguments.command == "tool":
            if not isinstance(loads(arguments.arguments), dict):
                raise ValueError("Tool arguments must be a JSON object")
            deployment.client("tool", arguments.name, arguments.arguments)
        elif arguments.command in {"approve", "deny"}:
            deployment.client(arguments.command, arguments.approval_id)
        else:
            getattr(deployment, arguments.command)()
    except (SampleError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
