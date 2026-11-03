import re
from dataclasses import dataclass
from typing import Literal

from jsonschema import Draft202012Validator, ValidationError

from .common import JsonObject, SampleError, encode


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    schema: JsonObject
    source: Literal["resources", "mqtt"]
    remote_name: str
    read_only: bool = True

    def model_tool(self) -> JsonObject:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.schema,
            },
        }

    def validate(self, arguments: JsonObject) -> None:
        try:
            Draft202012Validator(self.schema).validate(arguments)
        except ValidationError as error:
            raise SampleError(
                f"Invalid arguments for {self.name}: {error.message[:300]}"
            ) from error
        for field in ("limit", "max_messages", "timeout_ms", "duration_seconds"):
            if field in arguments and type(arguments[field]) is not int:
                raise SampleError(f"{field} must be an integer")
        if (
            self.name in {"get_asset", "get_device"}
            and re.fullmatch(r"(?=.{1,253}$)[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?", arguments["name"])
            is None
        ):
            raise SampleError("name must be a valid Kubernetes resource name")
        if (
            self.name == "plant-telemetry"
            and "machine_id" in arguments
            and "stage" not in arguments
        ):
            raise SampleError("machine_id requires stage")
        if self.name == "recommendation-publish":
            payload = {
                "idempotencyKey": arguments["idempotency_key"],
                "recommendation": arguments["recommendation"],
            }
            if len(encode(payload).encode()) > 16 * 1024:
                raise SampleError("Recommendation payload exceeds 16 KiB")


def catalog() -> dict[str, ToolSpec]:
    tools = {}
    for singular, plural in (("asset", "assets"), ("device", "devices")):
        name = f"list_{plural}"
        tools[name] = ToolSpec(
            name,
            f"List bounded, sanitized AIO {plural}.",
            {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 20},
                    "name_prefix": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 63,
                        "pattern": "^[a-z0-9][a-z0-9.-]*$",
                    },
                },
                "additionalProperties": False,
            },
            "resources",
            name,
        )
        name = f"get_{singular}"
        tools[name] = ToolSpec(
            name,
            f"Get one sanitized AIO {singular} by resource name.",
            {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 253,
                    }
                },
                "required": ["name"],
                "additionalProperties": False,
            },
            "resources",
            name,
        )
    tools["plant-telemetry"] = ToolSpec(
        "plant-telemetry",
        "Read up to 20 plant messages. Stage inference reads the configured inference "
        "results; machine_id person or safetygate selects one. Other stages read "
        "their configured topics.",
        {
            "type": "object",
            "properties": {
                "stage": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 63,
                    "pattern": "^[a-z0-9][a-z0-9-]*$",
                },
                "machine_id": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 63,
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9-]*$",
                },
                "max_messages": {"type": "integer", "minimum": 1, "maximum": 20, "default": 5},
                "timeout_ms": {"type": "integer", "minimum": 100, "maximum": 5000, "default": 3000},
            },
            "additionalProperties": False,
        },
        "mqtt",
        "mq_messages",
    )
    tools["camera-pan"] = ToolSpec(
        "camera-pan",
        "Pan the fixed ONVIF demo camera left or right for 1 to 6 seconds. "
        "The sidecar attempts an explicit stop; success requires verified IDLE status.",
        {
            "type": "object",
            "properties": {
                "direction": {"type": "string", "enum": ["left", "right"]},
                "duration_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 6,
                    "default": 2,
                },
            },
            "required": ["direction"],
            "additionalProperties": False,
        },
        "mqtt",
        "mq_camera_pan",
        read_only=False,
    )
    tools["recommendation-publish"] = ToolSpec(
        "recommendation-publish",
        "Request operator approval to publish a recommendation. "
        "This never publishes without host approval.",
        {
            "type": "object",
            "properties": {
                "idempotency_key": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 128,
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
                },
                "recommendation": {
                    "type": "object",
                    "properties": {
                        "summary": {"type": "string", "minLength": 1, "maxLength": 1000},
                        "severity": {
                            "type": "string",
                            "enum": ["LOW", "MEDIUM", "HIGH", "CRITICAL"],
                        },
                        "actions": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 10,
                            "items": {"type": "string", "minLength": 1, "maxLength": 500},
                        },
                        "evidence": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 20,
                            "items": {"type": "string", "minLength": 1, "maxLength": 500},
                        },
                    },
                    "required": ["summary", "severity", "actions", "evidence"],
                    "additionalProperties": False,
                },
            },
            "required": ["idempotency_key", "recommendation"],
            "additionalProperties": False,
        },
        "mqtt",
        "mq_publish",
        read_only=False,
    )
    return tools


def checked_tool(tools: dict[str, ToolSpec], name: str, arguments: JsonObject) -> ToolSpec:
    if name not in tools:
        raise SampleError(f"Tool is not permitted: {name}")
    tool = tools[name]
    tool.validate(arguments)
    return tool
