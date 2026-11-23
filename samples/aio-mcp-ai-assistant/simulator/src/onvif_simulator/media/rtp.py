from __future__ import annotations

import struct
import time
from collections.abc import Iterable

RTP_VERSION = 2
H264_PAYLOAD_TYPE = 96


def packetize_h264(
    nals: tuple[bytes, ...],
    *,
    sequence: int,
    timestamp: int,
    ssrc: int,
    max_payload: int = 1200,
) -> tuple[list[bytes], int]:
    packets: list[bytes] = []
    current_sequence = sequence
    payloads = list(_nal_payloads(nals, max_payload))
    for index, payload in enumerate(payloads):
        marker = index == len(payloads) - 1
        first_byte = RTP_VERSION << 6
        second_byte = H264_PAYLOAD_TYPE | (0x80 if marker else 0)
        header = struct.pack(
            "!BBHII",
            first_byte,
            second_byte,
            current_sequence,
            timestamp,
            ssrc,
        )
        packets.append(header + payload)
        current_sequence = (current_sequence + 1) & 0xFFFF
    return packets, current_sequence


def _nal_payloads(nals: tuple[bytes, ...], max_payload: int) -> Iterable[bytes]:
    for nal in nals:
        if not nal:
            continue
        if len(nal) <= max_payload:
            yield nal
            continue
        nal_header = nal[0]
        fu_indicator = (nal_header & 0xE0) | 28
        nal_type = nal_header & 0x1F
        body = nal[1:]
        chunk_size = max_payload - 2
        for offset in range(0, len(body), chunk_size):
            chunk = body[offset : offset + chunk_size]
            start = offset == 0
            end = offset + len(chunk) >= len(body)
            fu_header = nal_type | (0x80 if start else 0) | (0x40 if end else 0)
            yield bytes((fu_indicator, fu_header)) + chunk


def rtcp_sender_report(
    *,
    ssrc: int,
    rtp_timestamp: int,
    packet_count: int,
    octet_count: int,
) -> bytes:
    ntp = time.time() + 2_208_988_800
    ntp_seconds = int(ntp)
    ntp_fraction = int((ntp - ntp_seconds) * (1 << 32))
    return struct.pack(
        "!BBHIIIIII",
        RTP_VERSION << 6,
        200,
        6,
        ssrc,
        ntp_seconds,
        ntp_fraction,
        rtp_timestamp,
        packet_count & 0xFFFFFFFF,
        octet_count & 0xFFFFFFFF,
    )
