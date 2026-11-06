from __future__ import annotations

from base64 import b64encode
from datetime import UTC, datetime
from hashlib import sha1

from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.dispatcher import OnvifDispatcher
from onvif_simulator.onvif.namespaces import NSMAP, SOAP, TDS, TRT, WSA, WSSE, WSU
from onvif_simulator.onvif.xml import element, qname
from onvif_simulator.state import CameraState


def soap_request(
    settings: Settings,
    namespace: str,
    operation: str,
    *,
    authenticated: bool,
    children: dict[str, str] | None = None,
) -> bytes:
    envelope = etree.Element(qname(SOAP, "Envelope"), nsmap=NSMAP)
    header = element(envelope, SOAP, "Header")
    element(header, WSA, "Action", f"{namespace}/{operation}")
    element(header, WSA, "MessageID", "urn:uuid:test-message")
    if authenticated:
        security = element(header, WSSE, "Security")
        token = element(security, WSSE, "UsernameToken")
        element(token, WSSE, "Username", settings.camera_username)
        nonce = b"test-nonce"
        created = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        digest = b64encode(
            sha1(  # noqa: S324 - WS-Security UsernameToken requires SHA-1.
                nonce + created.encode() + settings.camera_password.get_secret_value().encode()
            ).digest()
        ).decode()
        password = element(token, WSSE, "Password", digest)
        password.set(
            "Type",
            (
                "http://docs.oasis-open.org/wss/2004/01/"
                "oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
            ),
        )
        element(token, WSSE, "Nonce", b64encode(nonce).decode())
        element(token, WSU, "Created", created)
    body = element(envelope, SOAP, "Body")
    request = element(body, namespace, operation)
    for name, value in (children or {}).items():
        element(request, namespace, name, value)
    return etree.tostring(envelope)


def test_system_time_is_available_before_authentication(settings: Settings) -> None:
    dispatcher = OnvifDispatcher(settings, CameraState(settings.state_path))

    result = dispatcher.dispatch(
        "/onvif/device_service",
        soap_request(settings, TDS, "GetSystemDateAndTime", authenticated=False),
        None,
    )

    assert result.status == 200
    assert b"GetSystemDateAndTimeResponse" in result.payload


def test_device_information_requires_valid_username_token(settings: Settings) -> None:
    dispatcher = OnvifDispatcher(settings, CameraState(settings.state_path))

    denied = dispatcher.dispatch(
        "/onvif/device_service",
        soap_request(settings, TDS, "GetDeviceInformation", authenticated=False),
        None,
    )
    accepted = dispatcher.dispatch(
        "/onvif/device_service",
        soap_request(settings, TDS, "GetDeviceInformation", authenticated=True),
        None,
    )
    accepted_by_transport = dispatcher.dispatch(
        "/onvif/device_service",
        soap_request(settings, TDS, "GetDeviceInformation", authenticated=False),
        None,
        transport_authenticated=True,
    )

    assert denied.status == 401
    assert b"NotAuthorized" in denied.payload
    assert accepted.status == 200
    assert settings.model.encode() in accepted.payload
    assert accepted_by_transport.status == 200


def test_media_profiles_use_service_namespace(settings: Settings) -> None:
    dispatcher = OnvifDispatcher(settings, CameraState(settings.state_path))

    result = dispatcher.dispatch(
        "/onvif/media_service",
        soap_request(settings, TRT, "GetProfiles", authenticated=True),
        None,
    )
    root = etree.fromstring(result.payload)

    assert result.status == 200
    assert root.xpath("count(//trt:GetProfilesResponse/trt:Profiles)", namespaces=NSMAP) == 2
    assert root.xpath("count(//trt:Profiles/tt:VideoEncoderConfiguration)", namespaces=NSMAP) == 2
