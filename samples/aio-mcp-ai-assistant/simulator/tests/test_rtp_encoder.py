from __future__ import annotations

from onvif_simulator.media.encoder import split_annex_b
from onvif_simulator.media.rtp import packetize_h264


def test_split_annex_b_extracts_nals() -> None:
    payload = b"\x00\x00\x00\x01\x67abc\x00\x00\x01\x68def"

    assert split_annex_b(payload) == (b"\x67abc", b"\x68def")


def test_packetizer_fragments_large_nal_and_marks_last_packet() -> None:
    nal = bytes([0x65]) + b"x" * 3000

    packets, next_sequence = packetize_h264(
        (nal,),
        sequence=10,
        timestamp=1234,
        ssrc=5678,
        max_payload=1000,
    )

    assert len(packets) == 4
    assert packets[0][12] & 0x1F == 28
    assert packets[0][13] & 0x80
    assert packets[-1][13] & 0x40
    assert packets[-1][1] & 0x80
    assert next_sequence == 14
