import asyncio
import json

import httpx
import pytest

from aio_mcp_ai_assistant.common import SampleError
from aio_mcp_ai_assistant.foundry import FoundryClient, read_completion


def event(delta, finish=None):
    return {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}


def stream(events, *, done=True):
    data = b"".join(
        ("data: " + json.dumps(item, ensure_ascii=False) + "\r\n\r\n").encode() for item in events
    )
    return data + (b"data: [DONE]\r\n\r\n" if done else b"")


async def chunks(data):
    for offset in range(0, len(data), 3):
        yield data[offset : offset + 3]


def test_sse_handles_utf8_boundaries_and_reads_only_delta_content():
    result = asyncio.run(
        read_completion(
            chunks(
                stream(
                    [
                        event({"reasoning_content": "Not public"}),
                        event({"content": "Observed caf\u00e9 sensor."}),
                        event({}, "stop"),
                    ]
                )
            )
        )
    )
    assert result.content == "Observed caf\u00e9 sensor."
    assert result.finish_reasons == ("stop",)


def test_empty_qwen_reasoning_prefix_is_not_rewritten():
    call = '<tool_call>{"name":"list_assets","arguments":{"limit":5}}</tool_call>'
    result = asyncio.run(
        read_completion(
            chunks(stream([event({"content": "<think>\n\n</think>\n\n" + call}, "stop")]))
        )
    )
    assert result.content == "<think>\n\n</think>\n\n" + call


def test_nonempty_reasoning_is_not_removed_from_a_tool_response():
    text = '<think>Not a tool result.</think><tool_call>{"name":"list_assets","arguments":{}}</tool_call>'
    result = asyncio.run(read_completion(chunks(stream([event({"content": text}, "stop")]))))
    assert result.content == text


def test_native_function_deltas_do_not_replace_the_original_text():
    text = '<tool_call>{"name":"list_devices","arguments":{"limit":1}}</tool_call>'
    result = asyncio.run(
        read_completion(
            chunks(
                stream(
                    [
                        event({"content": text}),
                        event(
                            {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "type": "function",
                                        "function": {"name": "list_", "arguments": '{"limit":'},
                                    }
                                ]
                            }
                        ),
                        event(
                            {
                                "tool_calls": [
                                    {"index": 0, "function": {"name": "assets", "arguments": "2}"}}
                                ]
                            }
                        ),
                        event({}, "tool_calls"),
                    ]
                )
            )
        )
    )
    assert result.content == text
    assert result.finish_reasons == ("tool_calls",)


def test_generation_limit_is_reported_without_rewriting_the_response(caplog):
    text = "<think>Not a complete public answer"
    result = asyncio.run(
        read_completion(chunks(stream([event({"content": text}, "length"), event({}, "stop")])))
    )
    assert result.content == text
    assert result.finish_reasons == ("length", "stop")
    assert "finish reason: length" in caplog.text


def test_done_terminates_a_content_stream_without_a_finish_reason():
    result = asyncio.run(read_completion(chunks(stream([event({"content": "Answer"})]))))
    assert result.content == "Answer"
    assert result.finish_reasons == ()


@pytest.mark.parametrize(
    "data",
    [
        stream([event({"content": "partial"}, "stop")], done=False),
        stream([event({"content": "malformed"}, {"unexpected": True})]),
        stream([event({"content": "malformed"}, {"unexpected": True}), event({}, "stop")]),
        b"data: {invalid}\n\n",
        b"data: {}",
        stream([event({"tool_calls": [{"index": False, "function": {"name": "list_assets"}}]})]),
        stream([event({"tool_calls": [{"index": 1, "function": {"name": "list_assets"}}]})]),
    ],
)
def test_incomplete_streams_invalid_events_and_native_only_responses_fail(data):
    with pytest.raises(SampleError):
        asyncio.run(read_completion(chunks(data)))


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
            headers={"content-type": "text/event-stream"},
            content=stream([event({"content": "Answer"}, "stop")]),
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
    assert all(json.loads(request.content)["stream"] is True for request in requests)
    assert all(json.loads(request.content)["max_tokens"] == 256 for request in requests)
    assert all(json.loads(request.content)["temperature"] == 0 for request in requests)
