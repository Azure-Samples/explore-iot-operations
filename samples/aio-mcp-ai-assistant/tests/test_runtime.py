import asyncio
import json
from copy import deepcopy

import pytest

from aio_mcp_ai_assistant.approvals import ApprovalStore
from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.foundry import Completion
from aio_mcp_ai_assistant.runtime import AgentBusy, Runtime
from aio_mcp_ai_assistant.tool_parser import ToolCallFormatError, parse_tool_call
from aio_mcp_ai_assistant.tools import catalog


class Model:
    def __init__(self, completions):
        self.completions = iter(completions)
        self.messages = []
        self.tools = []

    async def complete(self, messages, tools):
        self.messages.append(deepcopy(messages))
        self.tools.append(deepcopy(tools))
        return next(self.completions)


class Tools:
    def __init__(self, settings, source):
        self.tools = [
            {"name": tool.remote_name, "inputSchema": tool.schema}
            for tool in catalog().values()
            if tool.source == source
        ]
        self.calls = []

    async def list_tools(self):
        return self.tools

    async def call_tool(self, name, arguments):
        self.calls.append((name, arguments))
        if name == "mq_publish":
            return {"published": True}
        return {"items": [{"metadata": {"name": "camera-01"}}], "count": 1, "truncated": False}


def call(name, arguments):
    return Completion(
        "<tool_call>" + json.dumps({"name": name, "arguments": arguments}) + "</tool_call>"
    )


def runtime(settings, completions):
    return Runtime(
        settings,
        Model(completions),
        {"resources": Tools(settings, "resources"), "mqtt": Tools(settings, "mqtt")},
    )


def test_correlated_evidence_and_independent_questions(settings):
    first = call("list_assets", {"limit": 1})
    agent = runtime(
        settings,
        [
            first,
            Completion("The page contains camera-01."),
            first,
            Completion("The new page contains camera-01."),
        ],
    )

    async def run():
        result = await agent.ask("List assets")
        assert result["toolActivity"][0]["result"]["items"] == [{"metadata": {"name": "camera-01"}}]
        assert result["toolActivity"][0]["source"] == "resources"
        conversation = agent.foundry.messages[1]
        assert conversation[-1]["role"] == "tool"
        assert conversation[-1]["tool_call_id"] == conversation[-2]["tool_calls"][0]["id"]
        assert conversation[-2]["tool_calls"][0]["function"]["arguments"] == '{"limit": 1}'
        assert conversation[-1]["content"] == json.dumps(result["toolActivity"][0]["result"])
        await agent.ask("List assets again")
        assert len(agent.foundry.messages[2]) == 2
        assert agent.foundry.messages[2][-1]["content"] == "List assets again"

    asyncio.run(run())


def test_qwen_markup_enters_the_same_validated_tool_path(settings):
    agent = runtime(
        settings,
        [
            Completion(
                "<tool_call><function=list_assets>"
                "<parameter=limit>1</parameter></function></tool_call>"
            ),
            Completion("One asset was returned."),
        ],
    )
    result = asyncio.run(agent.ask("List one asset"))
    assert result["toolActivity"][0]["arguments"] == {"limit": 1}


@pytest.mark.parametrize(
    "completion, message",
    [
        (call("publish", {}), "not permitted"),
        (call("mq_messages", {}), "not permitted"),
        (call("plant-telemetry", {"source": "other"}), "Invalid arguments"),
        (call("plant-telemetry", {"machine_id": "person"}), "requires stage"),
        (call("plant-telemetry", {"timeout_ms": 100.0}), "must be an integer"),
        (call("list_assets", {"namespace": "other"}), "Invalid arguments"),
        (call("list_assets", {"limit": 1.0}), "must be an integer"),
    ],
)
def test_invalid_tools_or_arguments_fail_without_a_format_retry(settings, completion, message):
    agent = runtime(settings, [completion])
    with pytest.raises(SampleError, match=message):
        asyncio.run(agent.ask("Check the operation"))
    assert not any(client.calls for client in agent.clients.values())
    assert len(agent.foundry.messages) == 1


@pytest.mark.parametrize("text", ["Hello.", "<think>Unfinished model text"])
def test_plain_text_is_preserved_without_inventing_tool_activity(settings, text, caplog):
    agent = runtime(settings, [Completion(text)])
    result = asyncio.run(agent.ask("Hello"))
    assert result["answer"] == text
    assert result["toolActivity"] == []
    assert "without retrieving tool evidence" in caplog.text


def test_one_format_correction_routes_plant_telemetry_to_remote_mq_messages(settings):
    malformed = '<tool_call>{"name":"plant-telemetry","arguments":{</tool_call>'
    arguments = {"stage": "inference", "machine_id": "person", "max_messages": 1}
    agent = runtime(
        settings,
        [Completion(malformed), call("plant-telemetry", arguments), Completion("Read complete.")],
    )
    result = asyncio.run(agent.ask("Read the latest inference message"))
    correction = agent.foundry.messages[1]
    assert correction[-2] == {"role": "assistant", "content": malformed}
    assert correction[-1]["role"] == "user"
    assert "<function=TOOL><parameter=ARG>VALUE</parameter>" in correction[-1]["content"]
    assert agent.clients["mqtt"].calls == [("mq_messages", arguments)]
    assert result["toolActivity"][0]["tool"] == "plant-telemetry"
    assert agent.foundry.messages[2][-1]["name"] == "plant-telemetry"
    assert {tool["function"]["name"] for tool in agent.foundry.tools[0]} == {
        "list_assets",
        "get_asset",
        "list_devices",
        "get_device",
        "plant-telemetry",
        "camera-pan",
        "recommendation-publish",
    }


def test_a_second_malformed_call_fails_without_executing_either(settings):
    malformed = Completion("<tool_call>not a function</tool_call>")
    agent = runtime(settings, [malformed, malformed])
    with pytest.raises(ToolCallFormatError):
        asyncio.run(agent.ask("Read inference"))
    assert len(agent.foundry.messages) == 2
    assert not any(client.calls for client in agent.clients.values())


def test_catalog_drift_is_rejected_before_inference(settings):
    agent = runtime(settings, [])
    agent.clients["mqtt"].tools[0]["inputSchema"]["additionalProperties"] = True
    with pytest.raises(SampleError, match="schemas differ"):
        asyncio.run(agent.ask("Read observations"))
    assert not agent.foundry.messages


def test_four_completion_limit(settings):
    agent = runtime(settings, [call("list_assets", {})] * 5)
    with pytest.raises(SampleError, match="four completions"):
        asyncio.run(agent.ask("Keep listing"))
    assert len(agent.clients["resources"].calls) == 4
    assert len(agent.foundry.messages) == 4


def test_one_active_question(settings):
    agent = runtime(settings, [])

    async def run():
        async with agent.lock:
            with pytest.raises(AgentBusy):
                await agent.ask("A concurrent question")

    asyncio.run(run())


@pytest.mark.parametrize(
    "text",
    [
        'Prose <tool_call>{"name":"list_assets","arguments":{}}</tool_call>',
        '<think>Not evidence.</think><tool_call>{"name":"list_assets","arguments":{}}</tool_call>',
        '<tool_call>{"name":"list_assets","arguments":{},"arguments":{}}</tool_call>',
        "<tool_call><function=list_assets><parameter=limit>1</parameter>"
        "<parameter=limit>2</parameter></function></tool_call>",
        "<tool_call><function=list_assets></function></tool_call>" * 2,
    ],
)
def test_malformed_tool_markup_is_not_accepted_as_a_final_answer(text):
    with pytest.raises(SampleError):
        parse_tool_call(text)


def test_model_recommendation_stops_at_operator_approval(action_settings, recommendation):
    agent = runtime(action_settings, [call("recommendation-publish", recommendation)])
    result = asyncio.run(agent.ask("Prepare a recommendation for review"))
    assert result["status"] == "approval_required"
    assert result["published"] is False
    assert result["approval"]["arguments"] == recommendation
    assert result["toolActivity"][0]["tool"] == "recommendation-publish"
    assert len(agent.foundry.messages) == 1
    assert not agent.clients["mqtt"].calls


def test_direct_tool_requires_one_use_approval_and_preserves_reviewed_payload(
    action_settings, recommendation
):
    agent = runtime(action_settings, [])
    original = deepcopy(recommendation)

    async def run():
        pending = await agent.call_tool("recommendation-publish", recommendation)
        assert not agent.clients["mqtt"].calls
        pending["approval"]["arguments"]["recommendation"]["summary"] = "Changed response"
        recommendation["recommendation"]["summary"] = "Changed request"
        outcomes = await asyncio.gather(
            agent.decide_approval(pending["approval"]["id"], "approve"),
            agent.decide_approval(pending["approval"]["id"], "approve"),
            return_exceptions=True,
        )
        assert sum(isinstance(item, ValueError) for item in outcomes) == 1
        assert any(isinstance(item, dict) and item["status"] == "published" for item in outcomes)

    asyncio.run(run())
    assert agent.clients["mqtt"].calls == [("mq_publish", original)]


def test_denial_and_expiry_never_publish(action_settings, recommendation):
    agent = runtime(action_settings, [])

    async def run():
        pending = await agent.call_tool("recommendation-publish", recommendation)
        approval_id = pending["approval"]["id"]
        assert await agent.decide_approval(approval_id, "deny") == {
            "status": "denied",
            "published": False,
        }
        with pytest.raises(ValueError, match="not found"):
            await agent.decide_approval(approval_id, "approve")
        agent.approvals = ApprovalStore(lifetime_seconds=0)
        expired = await agent.call_tool("recommendation-publish", recommendation)
        with pytest.raises(ValueError, match="expired"):
            await agent.decide_approval(expired["approval"]["id"], "approve")

    asyncio.run(run())
    assert not agent.clients["mqtt"].calls


def test_disabled_actions_do_not_call_the_sidecar(settings, recommendation):
    agent = runtime(settings, [call("recommendation-publish", recommendation)])

    async def run():
        result = await agent.ask("Request publication")
        assert result["status"] == "completed"
        assert result["published"] is False
        assert result["approval"] is None
        with pytest.raises(SampleError, match="disabled"):
            await agent.call_tool("camera-pan", {"direction": "right"})

    asyncio.run(run())
    assert not agent.clients["mqtt"].calls


@pytest.mark.parametrize(
    "arguments",
    [
        {"direction": "up"},
        {"direction": "right", "duration_seconds": 7},
        {"direction": "left", "duration_seconds": True},
        {"direction": "right", "duration_seconds": 1.0},
        {"direction": "left", "topic": "other/camera"},
    ],
)
def test_invalid_camera_arguments_are_rejected_before_actuation(action_settings, arguments):
    agent = runtime(action_settings, [])
    with pytest.raises(SampleError):
        asyncio.run(agent.call_tool("camera-pan", arguments))
    assert not agent.clients["mqtt"].calls


def test_recommendation_byte_limit_applies_before_approval(action_settings, recommendation):
    recommendation["recommendation"]["evidence"] = ["\u754c" * 500] * 20
    agent = runtime(action_settings, [])
    with pytest.raises(SampleError, match="16 KiB"):
        asyncio.run(agent.call_tool("recommendation-publish", recommendation))
    assert not agent.approvals.items
