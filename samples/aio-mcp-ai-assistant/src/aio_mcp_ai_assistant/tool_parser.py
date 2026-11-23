import re
from dataclasses import dataclass
from typing import Any

from .common import JsonObject, SampleError, loads

_BLOCK = re.compile(r"\s*<tool_call>\s*(.*?)\s*</tool_call>\s*", re.DOTALL)
_FUNCTION = re.compile(
    r"<function=([A-Za-z0-9][A-Za-z0-9_-]{0,127})>\s*(.*?)\s*</function>", re.DOTALL
)
_PARAMETER = re.compile(
    r"<parameter=([A-Za-z_][A-Za-z0-9_]{0,127})>\s*(.*?)\s*</parameter>", re.DOTALL
)
_RESERVED = (
    "<tool_call",
    "</tool_call>",
    "<function=",
    "</function>",
    "<parameter=",
    "</parameter>",
)


class ToolCallFormatError(SampleError):
    pass


@dataclass(frozen=True)
class ToolCall:
    name: str
    arguments: JsonObject


def parse_tool_call(content: str) -> ToolCall | None:
    if not any(marker in content for marker in _RESERVED):
        return None
    block = _BLOCK.fullmatch(content)
    if block is None:
        raise ToolCallFormatError("Expected one exact tool-call block without surrounding text")
    inner = block.group(1)
    if inner.startswith("{"):
        try:
            call = loads(inner)
        except ValueError as error:
            raise ToolCallFormatError("Tool call contains invalid JSON") from error
        if (
            not isinstance(call, dict)
            or set(call) != {"name", "arguments"}
            or not isinstance(call["name"], str)
            or not isinstance(call["arguments"], dict)
        ):
            raise ToolCallFormatError("Tool call must contain a name and an arguments object")
        return ToolCall(call["name"], call["arguments"])
    function = _FUNCTION.fullmatch(inner)
    if function is None:
        raise ToolCallFormatError("Tool call contains invalid Qwen function markup")
    arguments: JsonObject = {}
    raw = function.group(2)
    cursor = 0
    for parameter in _PARAMETER.finditer(raw):
        if raw[cursor : parameter.start()].strip():
            raise ToolCallFormatError("Tool call contains text outside a parameter")
        name = parameter.group(1)
        if name in arguments:
            raise ToolCallFormatError("Tool call contains a duplicate parameter")
        arguments[name] = _parameter_value(parameter.group(2))
        cursor = parameter.end()
    if raw[cursor:].strip():
        raise ToolCallFormatError("Tool call contains text outside a parameter")
    return ToolCall(function.group(1), arguments)


def _parameter_value(value: str) -> Any:
    value = value.strip()
    try:
        return loads(value)
    except ValueError:
        return value
