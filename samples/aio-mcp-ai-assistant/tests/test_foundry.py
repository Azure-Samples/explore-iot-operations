import asyncio
import json

import httpx
import pytest

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.foundry import FoundryClient, read_completion


def completion(content, finish="stop", **message_fields):
    return {
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content, **message_fields},
                "finish_reason": finish,
            }
        ]
    }


class Chunks(httpx.AsyncByteStream):
    def __init__(self, data):
        self.data = data

    async def __aiter__(self):
        for offset in range(0, len(self.data), 3):
            yield self.data[offset : offset + 3]


def read(payload):
    data = json.dumps(payload, ensure_ascii=False).encode()
    return asyncio.run(read_completion(httpx.Response(200, stream=Chunks(data))))


def test_json_handles_utf8_boundaries_and_reads_only_message_content():
    result = read(completion("Observed caf\u00e9 sensor.", reasoning_content="Not public"))
    assert result.content == "Observed caf\u00e9 sensor."
    assert result.finish_reasons == ("stop",)


def test_empty_qwen_reasoning_prefix_is_not_rewritten():
    call = '<tool_call>{"name":"list_assets","arguments":{"limit":5}}</tool_call>'
    result = read(completion("<think>\n\n</think>\n\n" + call))
    assert result.content == "<think>\n\n</think>\n\n" + call


def test_nonempty_reasoning_is_not_removed_from_a_tool_response():
    text = '<think>Not a tool result.</think><tool_call>{"name":"list_assets","arguments":{}}</tool_call>'
    result = read(completion(text))
    assert result.content == text


def test_structured_functions_do_not_replace_the_original_text():
    text = '<tool_call>{"name":"list_devices","arguments":{"limit":1}}</tool_call>'
    result = read(
        completion(
            text,
            "tool_calls",
            tool_calls=[
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "list_assets", "arguments": '{"limit":2}'},
                }
            ],
        )
    )
    assert result.content == text
    assert result.finish_reasons == ("tool_calls",)


def test_generation_limit_is_reported_without_rewriting_the_response(caplog):
    text = "<think>Not a complete public answer"
    result = read(completion(text, "length"))
    assert result.content == text
    assert result.finish_reasons == ("length",)
    assert "finish reason: length" in caplog.text


@pytest.mark.parametrize(
    "payload",
    [
        [],
        {},
        {"choices": []},
        {"choices": [completion("First")["choices"][0], completion("Second")["choices"][0]]},
        {"choices": [{"index": False, "message": {"content": "Answer"}, "finish_reason": "stop"}]},
        {"choices": [{"index": 0, "message": None, "finish_reason": "stop"}]},
        completion(None, tool_calls=[{"function": {"name": "list_assets", "arguments": "{}"}}]),
        completion({"invalid": "content"}),
        completion(" "),
        completion("Answer", None),
        completion("Answer", {"invalid": True}),
    ],
)
def test_invalid_completions_and_structured_only_responses_fail(payload):
    with pytest.raises(SampleError):
        read(payload)


@pytest.mark.parametrize("data", [b'{"choices":', b'{"choices":[],"choices":[]}', b"\xff"])
def test_invalid_or_incomplete_json_fails(data):
    with pytest.raises(SampleError):
        asyncio.run(read_completion(httpx.Response(200, stream=Chunks(data))))


def test_completion_size_is_bounded(monkeypatch):
    data = json.dumps(completion("Answer")).encode()
    monkeypatch.setattr("aio_mcp_ai_assistant.foundry.MAX_COMPLETION_BYTES", len(data) - 1)
    with pytest.raises(SampleError, match="size limit"):
        asyncio.run(read_completion(httpx.Response(200, stream=Chunks(data))))


def test_endpoint_and_token_are_reread_for_each_completion(settings, tmp_path):
    token = tmp_path / "token"
    requests = []

    class Kube:
        calls = 0

        async def model_endpoint(self, _):
            self.calls += 1
            return f"https://model-{self.calls}.example.test"

    def respond(request):
        requests.append(request)
        return httpx.Response(
            200,
            headers={"content-type": "application/json; charset=utf-8"},
            json=completion("Answer"),
        )

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as http:
            client = FoundryClient(settings, Kube(), http, token_path=token)
            for value in ("test-token-one", "test-token-two"):
                token.write_text(value)
                await client.complete([{"role": "user", "content": "Read"}], [])

    asyncio.run(run())
    assert [request.url.host for request in requests] == [
        "model-1.example.test",
        "model-2.example.test",
    ]
    assert [request.headers["authorization"] for request in requests] == [
        "Bearer test-token-one",
        "Bearer test-token-two",
    ]
    assert all(json.loads(request.content)["stream"] is False for request in requests)
    assert all(request.headers["accept"] == "application/json" for request in requests)
    assert all(json.loads(request.content)["max_tokens"] == 256 for request in requests)
    assert all(json.loads(request.content)["temperature"] == 0 for request in requests)
