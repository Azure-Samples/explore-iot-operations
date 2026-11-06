from __future__ import annotations

import asyncio
import base64
import socket

from onvif_simulator.config import Settings
from onvif_simulator.image_catalog import ImageCatalog
from onvif_simulator.media.encoder import AccessUnit, VideoPipeline
from onvif_simulator.renderer import FrameRenderer
from onvif_simulator.rtsp import RtspServer, Transport, next_keyframe, rtp_packet_interval
from onvif_simulator.state import CameraState


def unused_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


async def test_next_keyframe_discards_inter_frames() -> None:
    queue: asyncio.Queue[AccessUnit] = asyncio.Queue()
    await queue.put(AccessUnit((b"inter-1",), 1, False))
    await queue.put(AccessUnit((b"inter-2",), 2, False))
    expected = AccessUnit((b"keyframe",), 3, True)
    await queue.put(expected)

    assert await next_keyframe(queue) == expected


def test_udp_packets_are_paced_across_frame_interval() -> None:
    interval = rtp_packet_interval(Transport(tcp=False), 100, 20)

    assert interval == 0.0005
    assert rtp_packet_interval(Transport(tcp=True), 100, 20) == 0.0


async def read_response(
    reader: asyncio.StreamReader,
) -> tuple[str, dict[str, str], bytes]:
    raw_headers = await reader.readuntil(b"\r\n\r\n")
    lines = raw_headers.decode().split("\r\n")
    headers = {
        name.strip().lower(): value.strip()
        for line in lines[1:]
        if line and ":" in line
        for name, value in [line.split(":", 1)]
    }
    content_length = int(headers.get("content-length", "0"))
    body = await reader.readexactly(content_length) if content_length else b""
    return lines[0], headers, body


async def test_rtsp_tcp_interleaved_stream(settings: Settings) -> None:
    port = unused_port()
    settings = settings.model_copy(update={"rtsp_port": port, "advertised_rtsp_port": port})
    catalog = ImageCatalog(settings.image_dir, settings.initial_image)
    state = CameraState(settings.state_path)
    renderer = FrameRenderer(catalog, state)
    pipeline = VideoPipeline(settings.profiles["standard"], renderer)
    server = RtspServer(settings, {"stream2": pipeline})
    authorization = base64.b64encode(
        f"{settings.camera_username}:{settings.camera_password.get_secret_value()}".encode()
    ).decode()

    await pipeline.start()
    await server.start()
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        writer.write(
            (
                f"DESCRIBE rtsp://127.0.0.1:{port}/stream2 RTSP/1.0\r\n"
                "CSeq: 1\r\n"
                f"Authorization: Basic {authorization}\r\n"
                "Accept: application/sdp\r\n\r\n"
            ).encode()
        )
        await writer.drain()
        status, _, sdp = await read_response(reader)
        assert status == "RTSP/1.0 200 OK"
        assert b"sprop-parameter-sets=" in sdp

        writer.write(
            (
                f"SETUP rtsp://127.0.0.1:{port}/stream2/trackID=0 RTSP/1.0\r\n"
                "CSeq: 2\r\n"
                f"Authorization: Basic {authorization}\r\n"
                "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n"
            ).encode()
        )
        await writer.drain()
        status, headers, _ = await read_response(reader)
        assert status == "RTSP/1.0 200 OK"
        session = headers["session"].split(";", 1)[0]

        writer.write(
            (
                f"PLAY rtsp://127.0.0.1:{port}/stream2 RTSP/1.0\r\n"
                "CSeq: 3\r\n"
                f"Authorization: Basic {authorization}\r\n"
                f"Session: {session}\r\n\r\n"
            ).encode()
        )
        await writer.drain()
        status, _, _ = await read_response(reader)
        assert status == "RTSP/1.0 200 OK"

        interleaved_header = await asyncio.wait_for(reader.readexactly(4), timeout=3)
        assert interleaved_header[0] == ord("$")
        payload_length = int.from_bytes(interleaved_header[2:4], "big")
        rtp_packet = await reader.readexactly(payload_length)
        assert rtp_packet[0] >> 6 == 2
    finally:
        writer.close()
        await writer.wait_closed()
        await server.stop()
        await pipeline.stop()
