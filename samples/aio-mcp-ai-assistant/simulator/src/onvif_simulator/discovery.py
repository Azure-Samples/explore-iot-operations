from __future__ import annotations

import asyncio
import logging
import socket
from typing import cast
from uuid import uuid4

from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.namespaces import NSMAP, SOAP, WSA, WSD
from onvif_simulator.onvif.xml import element, qname

LOGGER = logging.getLogger(__name__)
MULTICAST_GROUP = "239.255.255.250"
DISCOVERY_PORT = 3702


class DiscoveryProtocol(asyncio.DatagramProtocol):
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self._transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        try:
            parser = etree.XMLParser(
                resolve_entities=False,
                no_network=True,
                load_dtd=False,
                huge_tree=False,
            )
            envelope = etree.fromstring(data, parser=parser)
            body = envelope.find(qname(SOAP, "Body"))
            header = envelope.find(qname(SOAP, "Header"))
            if body is None or not len(body):
                return
            operation = etree.QName(body[0]).localname
            message = header.find(qname(WSA, "MessageID")) if header is not None else None
            if operation not in {"Probe", "Resolve"}:
                return
            response = self._response(operation, message.text if message is not None else None)
            if self._transport is not None:
                self._transport.sendto(response, addr)
        except etree.XMLSyntaxError:
            LOGGER.debug("ignored malformed WS-Discovery datagram", extra={"peer": addr})
        except Exception:
            LOGGER.exception("WS-Discovery response failed", extra={"peer": addr})

    def _response(self, operation: str, relates_to: str | None) -> bytes:
        envelope = etree.Element(qname(SOAP, "Envelope"), nsmap=NSMAP)
        header = element(envelope, SOAP, "Header")
        response_action = (
            "http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches"
            if operation == "Probe"
            else "http://schemas.xmlsoap.org/ws/2005/04/discovery/ResolveMatches"
        )
        element(header, WSA, "Action", response_action)
        element(header, WSA, "MessageID", f"urn:uuid:{uuid4()}")
        if relates_to:
            element(header, WSA, "RelatesTo", relates_to)
        element(header, WSD, "AppSequence", InstanceId="1", MessageNumber="1")
        body = element(envelope, SOAP, "Body")
        matches_name = "ProbeMatches" if operation == "Probe" else "ResolveMatches"
        match_name = "ProbeMatch" if operation == "Probe" else "ResolveMatch"
        matches = element(body, WSD, matches_name)
        match = element(matches, WSD, match_name)
        endpoint = element(match, WSA, "EndpointReference")
        element(endpoint, WSA, "Address", f"urn:uuid:{self._settings.serial_number}")
        element(match, WSD, "Types", "tdn:NetworkVideoTransmitter")
        element(
            match,
            WSD,
            "Scopes",
            (
                "onvif://www.onvif.org/type/video_encoder "
                "onvif://www.onvif.org/Profile/Streaming "
                "onvif://www.onvif.org/name/AIO_ONVIF_Simulator"
            ),
        )
        element(
            match,
            WSD,
            "XAddrs",
            f"{self._settings.http_base_url}/onvif/device_service",
        )
        element(match, WSD, "MetadataVersion", 1)
        return cast(bytes, etree.tostring(envelope, xml_declaration=True, encoding="UTF-8"))


class DiscoveryServer:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._transport: asyncio.DatagramTransport | None = None

    async def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", DISCOVERY_PORT))
        membership = socket.inet_aton(MULTICAST_GROUP) + socket.inet_aton("0.0.0.0")
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
        sock.setblocking(False)
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(
            lambda: DiscoveryProtocol(self._settings),
            sock=sock,
        )
        self._transport = transport

    async def stop(self) -> None:
        if self._transport is not None:
            self._transport.close()
            self._transport = None
