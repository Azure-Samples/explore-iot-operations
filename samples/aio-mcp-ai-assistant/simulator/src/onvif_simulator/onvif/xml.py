from __future__ import annotations

from dataclasses import dataclass
from typing import Any, cast
from uuid import uuid4

from lxml import etree

from onvif_simulator.onvif.namespaces import NSMAP, SOAP, WSA


class SoapFaultError(ValueError):
    def __init__(
        self,
        reason: str,
        subcode: str = "ter:InvalidArgVal",
        code: str = "s:Sender",
    ) -> None:
        super().__init__(reason)
        self.reason = reason
        self.subcode = subcode
        self.code = code


@dataclass(frozen=True)
class SoapRequest:
    envelope: etree._Element
    body: etree._Element
    operation: etree._Element
    action: str
    message_id: str | None


def qname(namespace: str, name: str) -> str:
    return f"{{{namespace}}}{name}"


def local_name(element: etree._Element) -> str:
    return cast(str, etree.QName(element).localname)


def parse_soap(payload: bytes, action_header: str | None = None) -> SoapRequest:
    parser = etree.XMLParser(
        resolve_entities=False,
        no_network=True,
        load_dtd=False,
        dtd_validation=False,
        recover=False,
        huge_tree=False,
        remove_comments=True,
    )
    try:
        envelope = etree.fromstring(payload, parser=parser)
    except etree.XMLSyntaxError as exc:
        raise SoapFaultError(f"invalid SOAP XML: {exc}", "ter:WellFormed") from exc
    if envelope.tag != qname(SOAP, "Envelope"):
        raise SoapFaultError("request is not a SOAP 1.2 envelope", "ter:WellFormed")
    body = envelope.find(qname(SOAP, "Body"))
    if body is None or len(body) != 1:
        raise SoapFaultError("SOAP body must contain exactly one operation", "ter:WellFormed")
    operation = body[0]
    header = envelope.find(qname(SOAP, "Header"))
    xml_action = None
    message_id = None
    if header is not None:
        action_node = header.find(qname(WSA, "Action"))
        message_node = header.find(qname(WSA, "MessageID"))
        xml_action = action_node.text if action_node is not None else None
        message_id = message_node.text if message_node is not None else None
    action = (xml_action or action_header or "").strip('"')
    if not action:
        action = f"{etree.QName(operation).namespace}/{local_name(operation)}"
    return SoapRequest(envelope, body, operation, action, message_id)


def element(
    parent: etree._Element,
    namespace: str,
    name: str,
    text: Any | None = None,
    **attributes: str,
) -> etree._Element:
    child = etree.SubElement(parent, qname(namespace, name), attrib=attributes)
    if text is not None:
        if isinstance(text, bool):
            child.text = "true" if text else "false"
        else:
            child.text = str(text)
    return child


def response_envelope(
    payload: etree._Element,
    request_action: str,
    message_id: str | None,
) -> bytes:
    envelope = etree.Element(qname(SOAP, "Envelope"), nsmap=NSMAP)
    header = element(envelope, SOAP, "Header")
    action = request_action if request_action.endswith("Response") else f"{request_action}Response"
    element(header, WSA, "Action", action, mustUnderstand="true")
    if message_id:
        element(header, WSA, "RelatesTo", message_id)
    element(header, WSA, "MessageID", f"urn:uuid:{uuid4()}")
    body = element(envelope, SOAP, "Body")
    body.append(payload)
    return cast(bytes, etree.tostring(envelope, xml_declaration=True, encoding="UTF-8"))


def fault_envelope(
    reason: str,
    subcode: str,
    code: str = "s:Sender",
    message_id: str | None = None,
) -> bytes:
    envelope = etree.Element(qname(SOAP, "Envelope"), nsmap=NSMAP)
    header = element(envelope, SOAP, "Header")
    element(
        header,
        WSA,
        "Action",
        "http://www.w3.org/2005/08/addressing/fault",
        mustUnderstand="true",
    )
    if message_id:
        element(header, WSA, "RelatesTo", message_id)
    body = element(envelope, SOAP, "Body")
    fault = element(body, SOAP, "Fault")
    code_node = element(fault, SOAP, "Code")
    element(code_node, SOAP, "Value", code)
    if subcode:
        subcode_node = element(code_node, SOAP, "Subcode")
        element(subcode_node, SOAP, "Value", subcode)
    reason_node = element(fault, SOAP, "Reason")
    text = element(reason_node, SOAP, "Text", reason)
    text.set("{http://www.w3.org/XML/1998/namespace}lang", "en")
    return cast(bytes, etree.tostring(envelope, xml_declaration=True, encoding="UTF-8"))


def child(
    parent: etree._Element,
    name: str,
    *,
    required: bool = False,
) -> etree._Element | None:
    matches = parent.xpath(f"./*[local-name()='{name}']")
    if not matches:
        if required:
            raise SoapFaultError(f"missing required {name}", "ter:InvalidArgVal")
        return None
    return matches[0]


def child_text(
    parent: etree._Element,
    name: str,
    *,
    required: bool = False,
    default: str | None = None,
) -> str | None:
    node = child(parent, name, required=required)
    if node is None:
        return default
    value = (node.text or "").strip()
    if required and not value:
        raise SoapFaultError(f"{name} must not be empty", "ter:InvalidArgVal")
    return value or default


def float_attribute(
    parent: etree._Element | None,
    name: str,
    default: float = 0.0,
) -> float:
    if parent is None or name not in parent.attrib:
        return default
    try:
        return float(parent.attrib[name])
    except ValueError as exc:
        raise SoapFaultError(f"{name} must be a floating point value") from exc


def bool_text(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"true", "1"}:
        return True
    if normalized in {"false", "0"}:
        return False
    raise SoapFaultError(f"invalid boolean value {value!r}")
