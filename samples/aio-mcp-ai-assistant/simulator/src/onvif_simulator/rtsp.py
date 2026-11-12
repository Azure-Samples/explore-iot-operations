from __future__ import annotations

import asyncio
import contextlib
import logging
import secrets
import socket
import struct
from dataclasses import dataclass, field
from urllib.parse import urlsplit

from onvif_simulator.authentication import (
    digest_challenge,
    is_basic_authorized,
    is_digest_authorized,
)
from onvif_simulator.config import Settings
from onvif_simulator.media.encoder import AccessUnit, VideoPipeline
from onvif_simulator.media.rtp import packetize_h264, rtcp_sender_report

LOGGER = logging.getLogger(__name__)


@dataclass
class RtspRequest:
    method: str
    uri: str
    version: str
    headers: dict[str, str]
    body: bytes


@dataclass
class Transport:
    tcp: bool
    rtp_channel: int = 0
    rtcp_channel: int = 1
    client_rtp_port: int | None = None
    client_rtcp_port: int | None = None
    server_rtp_socket: socket.socket | None = None
    server_rtcp_socket: socket.socket | None = None


@dataclass
class RtspSession:
    identifier: str
    pipeline: VideoPipeline
    transport: Transport
    queue: asyncio.Queue[AccessUnit]
    sequence: int = field(default_factory=lambda: secrets.randbelow(65536))
    ssrc: int = field(default_factory=lambda: secrets.randbelow(0xFFFFFFFF) + 1)
    sender_task: asyncio.Task[None] | None = None
    packet_count: int = 0
    octet_count: int = 0


async def next_keyframe(queue: asyncio.Queue[AccessUnit]) -> AccessUnit:
    while True:
        access_unit = await queue.get()
        if access_unit.keyframe:
            return access_unit


def rtp_packet_interval(transport: Transport, packet_count: int, frame_rate: int) -> float:
    if transport.tcp or packet_count <= 1:
        return 0.0
    return 1.0 / (frame_rate * packet_count)


class RtspServer:
    def __init__(self, settings: Settings, pipelines: dict[str, VideoPipeline]) -> None:
        self._settings = settings
        self._pipelines = pipelines
        self._server: asyncio.Server | None = None
        self._nonce = secrets.token_hex(16)

    async def start(self) -> None:
        self._server = await asyncio.start_server(
            self._handle_connection,
            self._settings.bind_host,
            self._settings.rtsp_port,
        )

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def _handle_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("peername")
        write_lock = asyncio.Lock()
        session: RtspSession | None = None
        try:
            while not reader.at_eof():
                request = await self._read_request(reader)
                if request is None:
                    break
                cseq = request.headers.get("cseq", "0")
                if request.method != "OPTIONS" and not self._authorized(request):
                    await self._write_response(
                        writer,
                        write_lock,
                        401,
                        "Unauthorized",
                        cseq,
                        headers={"WWW-Authenticate": digest_challenge(self._nonce)},
                    )
                    continue

                if request.method == "OPTIONS":
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={
                            "Public": (
                                "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"
                            )
                        },
                    )
                elif request.method == "DESCRIBE":
                    pipeline = self._pipeline_for_uri(request.uri)
                    sdp = self._sdp(pipeline).encode()
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={
                            "Content-Type": "application/sdp",
                            "Content-Base": request.uri.rstrip("/") + "/",
                        },
                        body=sdp,
                    )
                elif request.method == "SETUP":
                    if session is not None:
                        await self._write_response(
                            writer,
                            write_lock,
                            459,
                            "Aggregate Operation Not Allowed",
                            cseq,
                        )
                        continue
                    pipeline = self._pipeline_for_uri(request.uri)
                    transport = self._parse_transport(request.headers.get("transport", ""))
                    session = RtspSession(
                        secrets.token_hex(8),
                        pipeline,
                        transport,
                        pipeline.subscribe(),
                    )
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={
                            "Session": f"{session.identifier};timeout=60",
                            "Transport": self._transport_response(transport),
                        },
                    )
                elif request.method == "PLAY":
                    session = self._require_session(request, session)
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={
                            "Session": session.identifier,
                            "RTP-Info": (
                                f"url={request.uri.rstrip('/')}/trackID=0;"
                                f"seq={session.sequence};rtptime=0"
                            ),
                        },
                    )
                    if session.sender_task is None or session.sender_task.done():
                        session.sender_task = asyncio.create_task(
                            self._send_media(session, writer, write_lock, peer),
                            name=f"rtsp-{session.identifier}",
                        )
                elif request.method == "PAUSE":
                    session = self._require_session(request, session)
                    await self._cancel_sender(session)
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={"Session": session.identifier},
                    )
                elif request.method == "TEARDOWN":
                    session = self._require_session(request, session)
                    await self._write_response(
                        writer,
                        write_lock,
                        200,
                        "OK",
                        cseq,
                        headers={"Session": session.identifier},
                    )
                    break
                elif request.method == "GET_PARAMETER":
                    headers = {"Session": session.identifier} if session else {}
                    await self._write_response(writer, write_lock, 200, "OK", cseq, headers=headers)
                else:
                    await self._write_response(writer, write_lock, 405, "Method Not Allowed", cseq)
        except (ConnectionError, asyncio.IncompleteReadError):
            LOGGER.debug("RTSP client disconnected", extra={"peer": peer})
        except ValueError as exc:
            LOGGER.warning("RTSP request rejected: %s", exc, extra={"peer": peer})
            with contextlib.suppress(ConnectionError):
                await self._write_response(writer, write_lock, 400, "Bad Request", "0")
        except Exception:
            LOGGER.exception("RTSP connection failed", extra={"peer": peer})
        finally:
            if session is not None:
                await self._close_session(session)
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    async def _read_request(self, reader: asyncio.StreamReader) -> RtspRequest | None:
        while True:
            first = await reader.read(1)
            if not first:
                return None
            if first == b"$":
                header = await reader.readexactly(3)
                length = struct.unpack("!H", header[1:])[0]
                await reader.readexactly(length)
                continue
            raw = first + await reader.readuntil(b"\r\n\r\n")
            break
        header_text = raw.decode("utf-8")
        lines = header_text.split("\r\n")
        parts = lines[0].split(" ", 2)
        if len(parts) != 3 or parts[2] != "RTSP/1.0":
            raise ValueError("invalid RTSP request line")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if not line:
                continue
            if ":" not in line:
                raise ValueError("invalid RTSP header")
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        if length < 0 or length > 1_048_576:
            raise ValueError("invalid RTSP content length")
        body = await reader.readexactly(length) if length else b""
        return RtspRequest(parts[0], parts[1], parts[2], headers, body)

    def _authorized(self, request: RtspRequest) -> bool:
        authorization = request.headers.get("authorization", "")
        return is_basic_authorized(
            authorization,
            self._settings.camera_username,
            self._settings.camera_password.get_secret_value(),
        ) or is_digest_authorized(
            authorization,
            method=request.method,
            uri=request.uri,
            nonce=self._nonce,
            username=self._settings.camera_username,
            password=self._settings.camera_password.get_secret_value(),
        )

    def _pipeline_for_uri(self, uri: str) -> VideoPipeline:
        path = urlsplit(uri).path.strip("/")
        profile_path = path.split("/", 1)[0]
        pipeline = self._pipelines.get(profile_path)
        if pipeline is None:
            raise ValueError(f"unknown RTSP stream {profile_path!r}")
        return pipeline

    @staticmethod
    def _parse_transport(value: str) -> Transport:
        if not value:
            raise ValueError("Transport header is required")
        alternatives = [item.strip() for item in value.split(",")]
        for candidate in alternatives:
            parts = [item.strip() for item in candidate.split(";")]
            protocol = parts[0].upper()
            parameters = {
                item.split("=", 1)[0].lower(): item.split("=", 1)[1]
                for item in parts[1:]
                if "=" in item
            }
            if protocol == "RTP/AVP/TCP":
                channels = parameters.get("interleaved", "0-1").split("-", 1)
                return Transport(True, int(channels[0]), int(channels[-1]))
            if protocol in {"RTP/AVP", "RTP/AVP/UDP"} and "client_port" in parameters:
                ports = parameters["client_port"].split("-", 1)
                rtp_socket = RtspServer._udp_socket()
                rtcp_socket = RtspServer._udp_socket()
                return Transport(
                    False,
                    client_rtp_port=int(ports[0]),
                    client_rtcp_port=int(ports[-1]),
                    server_rtp_socket=rtp_socket,
                    server_rtcp_socket=rtcp_socket,
                )
        raise ValueError("no supported RTSP transport was requested")

    @staticmethod
    def _udp_socket() -> socket.socket:
        result = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        result.bind(("0.0.0.0", 0))
        result.setblocking(False)
        return result

    @staticmethod
    def _transport_response(transport: Transport) -> str:
        if transport.tcp:
            return (
                f"RTP/AVP/TCP;unicast;interleaved={transport.rtp_channel}-{transport.rtcp_channel}"
            )
        if (
            transport.server_rtp_socket is None
            or transport.server_rtcp_socket is None
            or transport.client_rtp_port is None
            or transport.client_rtcp_port is None
        ):
            raise RuntimeError("incomplete UDP transport")
        server_rtp = transport.server_rtp_socket.getsockname()[1]
        server_rtcp = transport.server_rtcp_socket.getsockname()[1]
        return (
            "RTP/AVP;unicast;"
            f"client_port={transport.client_rtp_port}-{transport.client_rtcp_port};"
            f"server_port={server_rtp}-{server_rtcp}"
        )

    @staticmethod
    def _require_session(
        request: RtspRequest,
        session: RtspSession | None,
    ) -> RtspSession:
        supplied = request.headers.get("session", "").split(";", 1)[0]
        if session is None or supplied != session.identifier:
            raise ValueError("unknown or missing RTSP session")
        return session

    async def _send_media(
        self,
        session: RtspSession,
        writer: asyncio.StreamWriter,
        write_lock: asyncio.Lock,
        peer: object,
    ) -> None:
        loop = asyncio.get_running_loop()
        peer_host = peer[0] if isinstance(peer, tuple) else None
        last_report = loop.time()
        try:
            access_unit = await next_keyframe(session.queue)
            while True:
                packets, session.sequence = packetize_h264(
                    access_unit.nals,
                    sequence=session.sequence,
                    timestamp=access_unit.timestamp,
                    ssrc=session.ssrc,
                )
                packet_interval = rtp_packet_interval(
                    session.transport,
                    len(packets),
                    session.pipeline.profile.frame_rate,
                )
                for index, packet in enumerate(packets):
                    await self._send_packet(
                        session.transport,
                        packet,
                        False,
                        writer,
                        write_lock,
                        peer_host,
                    )
                    session.packet_count += 1
                    session.octet_count += len(packet) - 12
                    if packet_interval and index + 1 < len(packets):
                        await asyncio.sleep(packet_interval)
                if loop.time() - last_report >= 5.0:
                    report = rtcp_sender_report(
                        ssrc=session.ssrc,
                        rtp_timestamp=access_unit.timestamp,
                        packet_count=session.packet_count,
                        octet_count=session.octet_count,
                    )
                    await self._send_packet(
                        session.transport,
                        report,
                        True,
                        writer,
                        write_lock,
                        peer_host,
                    )
                    last_report = loop.time()
                access_unit = await session.queue.get()
        except asyncio.CancelledError:
            raise
        except (ConnectionError, OSError):
            LOGGER.debug("RTSP media sender stopped", extra={"session": session.identifier})

    @staticmethod
    async def _send_packet(
        transport: Transport,
        packet: bytes,
        rtcp: bool,
        writer: asyncio.StreamWriter,
        write_lock: asyncio.Lock,
        peer_host: str | None,
    ) -> None:
        if transport.tcp:
            channel = transport.rtcp_channel if rtcp else transport.rtp_channel
            frame = b"$" + bytes((channel,)) + struct.pack("!H", len(packet)) + packet
            async with write_lock:
                writer.write(frame)
                await writer.drain()
            return
        target_port = transport.client_rtcp_port if rtcp else transport.client_rtp_port
        udp_socket = transport.server_rtcp_socket if rtcp else transport.server_rtp_socket
        if peer_host is None or target_port is None or udp_socket is None:
            raise RuntimeError("incomplete UDP transport")
        await asyncio.get_running_loop().sock_sendto(udp_socket, packet, (peer_host, target_port))

    async def _close_session(self, session: RtspSession) -> None:
        await self._cancel_sender(session)
        session.pipeline.unsubscribe(session.queue)
        for udp_socket in (
            session.transport.server_rtp_socket,
            session.transport.server_rtcp_socket,
        ):
            if udp_socket is not None:
                udp_socket.close()

    @staticmethod
    async def _cancel_sender(session: RtspSession) -> None:
        if session.sender_task is not None:
            session.sender_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await session.sender_task
            session.sender_task = None

    def _sdp(self, pipeline: VideoPipeline) -> str:
        profile = pipeline.profile
        return "\r\n".join(
            (
                "v=0",
                f"o=- 0 0 IN IP4 {self._settings.advertised_host}",
                "s=ONVIF Camera Simulator",
                "t=0 0",
                "a=control:*",
                "m=video 0 RTP/AVP 96",
                "c=IN IP4 0.0.0.0",
                "a=rtpmap:96 H264/90000",
                (
                    "a=fmtp:96 packetization-mode=1;"
                    f"profile-level-id={pipeline.profile_level_id};"
                    f"sprop-parameter-sets={pipeline.sprop_parameter_sets}"
                ),
                "a=control:trackID=0",
                f"a=framerate:{profile.frame_rate}",
                "",
            )
        )

    @staticmethod
    async def _write_response(
        writer: asyncio.StreamWriter,
        lock: asyncio.Lock,
        status: int,
        reason: str,
        cseq: str,
        *,
        headers: dict[str, str] | None = None,
        body: bytes = b"",
    ) -> None:
        response_headers = {
            "CSeq": cseq,
            "Server": "AIO-ONVIF-Simulator/0.1",
            **(headers or {}),
        }
        if body:
            response_headers["Content-Length"] = str(len(body))
        lines = [f"RTSP/1.0 {status} {reason}"]
        lines.extend(f"{name}: {value}" for name, value in response_headers.items())
        payload = ("\r\n".join(lines) + "\r\n\r\n").encode() + body
        async with lock:
            writer.write(payload)
            await writer.drain()
