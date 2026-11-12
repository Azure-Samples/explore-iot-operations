import asyncio
import json
import logging
import time
import uuid
from pathlib import Path
from typing import Protocol

from .approvals import ApprovalStore
from .common import JsonObject, SampleError
from .config import Settings
from .foundry import Completion
from .frontend import verify_catalog
from .tool_parser import ToolCallFormatError, parse_tool_call
from .tools import catalog, checked_tool

LOGGER = logging.getLogger(__name__)


class CompletionClient(Protocol):
    async def complete(self, messages: list[JsonObject], tools: list[JsonObject]) -> Completion: ...


class ToolClient(Protocol):
    async def list_tools(self) -> list[JsonObject]: ...

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject: ...

    async def camera_status(self) -> JsonObject: ...


class AgentBusy(SampleError):
    pass


class Runtime:
    def __init__(self, settings: Settings, foundry: CompletionClient, frontend: ToolClient) -> None:
        self.settings = settings
        self.foundry = foundry
        self.frontend = frontend
        self.tools = catalog()
        self.prompt = (
            Path(__file__)
            .with_name("system_prompt.txt")
            .read_text()
            .replace(
                "{{telemetry_bindings}}",
                json.dumps(
                    [source.model_dump() for source in settings.sources.values()],
                    ensure_ascii=True,
                ),
            )
            .replace("{{camera_enabled}}", str(settings.camera.enabled).lower())
            .replace("{{publishing_enabled}}", str(settings.recommendations.enabled).lower())
        )
        self.lock = asyncio.Lock()
        self.approvals = ApprovalStore()

    async def discover(self) -> JsonObject:
        verify_catalog(await self.frontend.list_tools(), self.settings)
        return {"tools": sorted(self.tools), "mcpEndpoint": self.settings.mcp_url}

    async def call_tool(self, name: str, arguments: JsonObject) -> JsonObject:
        checked_tool(self.tools, name, arguments)
        if name == "camera-pan" and not self.settings.camera.enabled:
            raise SampleError("Camera movement is disabled in this deployment")
        if name == "recommendation-publish":
            if not self.settings.recommendations.enabled:
                return {
                    "status": "disabled",
                    "published": False,
                    "answer": "I prepared a recommendation, but publishing is disabled.",
                    "approval": None,
                }
            approval = await self.approvals.create(arguments)
            return {
                "status": "approval_required",
                "published": False,
                "answer": "Operator approval is required before publishing.",
                "approval": approval.as_json(),
            }
        return await self.frontend.call_tool(name, arguments)

    async def decide_approval(self, approval_id: str, decision: str) -> JsonObject:
        if decision not in {"approve", "deny"}:
            raise ValueError("decision must be approve or deny")
        if decision == "approve" and not self.settings.recommendations.enabled:
            raise SampleError("Recommendation publishing is disabled in this deployment")
        approval = await self.approvals.take(approval_id)
        if decision == "deny":
            return {"status": "denied", "published": False}
        checked_tool(self.tools, "recommendation-publish", approval.arguments)
        result = await self.frontend.call_tool("recommendation-publish", approval.arguments)
        published = result.get("published") is True
        if not published and result.get("duplicate") is not True:
            raise SampleError("AIO frontend adapter did not confirm publication or a duplicate key")
        return {
            "status": "published" if published else "not_published",
            "published": published,
            "result": result,
        }

    async def ask(self, question: str) -> JsonObject:
        if not isinstance(question, str) or not question.strip() or len(question) > 4000:
            raise ValueError("question must contain 1-4000 characters")
        if self.lock.locked():
            raise AgentBusy("Another question is running; retry after it completes")
        async with self.lock:
            try:
                return await asyncio.wait_for(self._ask(question), timeout=300)
            except asyncio.TimeoutError as error:
                raise SampleError("The question exceeded its 300-second deadline") from error

    async def _ask(self, question: str) -> JsonObject:
        started = time.time_ns() // 1_000_000
        await self.discover()
        conversation: list[JsonObject] = [
            {"role": "system", "content": self.prompt},
            {"role": "user", "content": question},
        ]
        activity: list[JsonObject] = []
        completions: list[JsonObject] = []
        format_correction_used = False
        for _ in range(4):
            completion = await self.foundry.complete(
                conversation, [tool.model_tool() for tool in self.tools.values()]
            )
            completions.append({"finishReasons": list(completion.finish_reasons)})
            try:
                call = parse_tool_call(completion.content)
            except ToolCallFormatError:
                if format_correction_used:
                    raise
                format_correction_used = True
                LOGGER.warning("Malformed model tool call; requesting one format correction")
                conversation.extend(
                    [
                        {"role": "assistant", "content": completion.content},
                        {
                            "role": "user",
                            "content": (
                                "Your tool call was malformed. If a tool is needed, reply with "
                                "only <tool_call><function=TOOL>"
                                "<parameter=ARG>VALUE</parameter>"
                                "</function></tool_call>. Otherwise answer without "
                                "tool-call markup."
                            ),
                        },
                    ]
                )
                continue
            if call is None:
                if not activity:
                    LOGGER.warning("Model returned a final answer without retrieving tool evidence")
                return {
                    "schemaVersion": 1,
                    "status": "completed",
                    "requestId": uuid.uuid4().hex,
                    "model": self.settings.model_id,
                    "startedAtUnixMs": started,
                    "completedAtUnixMs": time.time_ns() // 1_000_000,
                    "answer": completion.content,
                    "toolActivity": activity,
                    "modelCompletions": completions,
                }
            tool = checked_tool(self.tools, call.name, call.arguments)
            result = await self.call_tool(call.name, call.arguments)
            activity.append(
                {
                    "tool": call.name,
                    "source": tool.source,
                    "arguments": call.arguments,
                    "result": result,
                }
            )
            if call.name == "recommendation-publish":
                return {
                    "schemaVersion": 1,
                    **result,
                    "status": (
                        "completed" if result["status"] == "disabled" else "approval_required"
                    ),
                    "requestId": uuid.uuid4().hex,
                    "model": self.settings.model_id,
                    "startedAtUnixMs": started,
                    "completedAtUnixMs": time.time_ns() // 1_000_000,
                    "toolActivity": activity,
                    "modelCompletions": completions,
                }
            call_id = f"call_{len(activity)}"
            conversation.extend(
                [
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": call_id,
                                "type": "function",
                                "function": {
                                    "name": call.name,
                                    "arguments": json.dumps(call.arguments, allow_nan=False),
                                },
                            }
                        ],
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call_id,
                        "name": call.name,
                        "content": json.dumps(result, ensure_ascii=True, allow_nan=False),
                    },
                ]
            )
        raise SampleError("Model-call limit exceeded before a final response (four completions)")
