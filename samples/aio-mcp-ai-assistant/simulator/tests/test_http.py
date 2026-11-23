from __future__ import annotations

import base64
import re
from collections.abc import Callable

import pytest
from aiohttp.test_utils import TestClient, TestServer

from onvif_simulator.app import Simulator
from onvif_simulator.authentication import REALM
from onvif_simulator.config import Settings

SOAP_ACTION = "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation"
SOAP_REQUEST = b"""\
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <s:Body><tds:GetDeviceInformation /></s:Body>
</s:Envelope>
"""


async def test_switch_image_requires_admin_token(settings: Settings) -> None:
    simulator = Simulator(settings)
    async with TestClient(TestServer(simulator.web_app)) as client:
        denied = await client.get("/switch_image?name=warehouse.png")
        accepted = await client.get(
            "/switch_image?name=warehouse.png",
            headers={"Authorization": "Bearer test-admin-token"},
        )

        assert denied.status == 401
        assert accepted.status == 200
        assert (await accepted.json())["active_image"] == "warehouse.png"


async def test_snapshot_requires_camera_credentials(settings: Settings) -> None:
    simulator = Simulator(settings)
    credentials = base64.b64encode(
        f"{settings.camera_username}:{settings.camera_password.get_secret_value()}".encode()
    ).decode()
    async with TestClient(TestServer(simulator.web_app)) as client:
        denied = await client.get("/onvif/snapshot/profile_high.jpg")
        accepted = await client.get(
            "/onvif/snapshot/profile_high.jpg",
            headers={"Authorization": f"Basic {credentials}"},
        )

        assert denied.status == 401
        assert accepted.status == 200
        assert accepted.headers["Content-Type"] == "image/jpeg"


async def test_soap_supports_http_digest_authentication(
    settings: Settings, digest_header: Callable[..., str]
) -> None:
    simulator = Simulator(settings)
    uri = "/onvif/device_service"
    headers = {
        "Content-Type": f'application/soap+xml; action="{SOAP_ACTION}"',
    }
    async with TestClient(TestServer(simulator.web_app)) as client:
        denied = await client.post(uri, data=SOAP_REQUEST, headers=headers)

        assert denied.status == 401
        challenge = denied.headers["WWW-Authenticate"]
        assert challenge.startswith(f'Digest realm="{REALM}"')
        nonce_match = re.search(r'nonce="([^"]+)"', challenge)
        assert nonce_match is not None

        authorization = digest_header(nonce_match.group(1), uri=uri)
        accepted = await client.post(
            uri,
            data=SOAP_REQUEST,
            headers={**headers, "Authorization": authorization},
        )

        assert accepted.status == 200
        assert b"GetDeviceInformationResponse" in await accepted.read()


@pytest.mark.parametrize("replay_pan", ["0.5", "-0.5"])
async def test_digest_replay_cannot_repeat_or_change_camera_movement(
    settings: Settings, digest_header: Callable[..., str], replay_pan: str
) -> None:
    simulator = Simulator(settings)
    uri = "/onvif/ptz_service"
    body = """\
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
            xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Body><tptz:ContinuousMove>
    <tptz:ProfileToken>profile_high</tptz:ProfileToken>
    <tptz:Velocity><tt:PanTilt x="{pan}" y="0"/></tptz:Velocity>
    <tptz:Timeout>PT1S</tptz:Timeout>
  </tptz:ContinuousMove></s:Body>
</s:Envelope>
"""
    headers = {"Content-Type": "application/soap+xml"}
    async with TestClient(TestServer(simulator.web_app)) as client:
        challenge = await client.post(uri, data=body.format(pan="0.5"), headers=headers)
        nonce_match = re.search(r'nonce="([^"]+)"', challenge.headers["WWW-Authenticate"])
        assert nonce_match is not None
        headers["Authorization"] = digest_header(nonce_match.group(1), uri=uri)
        accepted = await client.post(uri, data=body.format(pan="0.5"), headers=headers)
        assert accepted.status == 200
        before = simulator.state.snapshot()
        replay = await client.post(uri, data=body.format(pan=replay_pan), headers=headers)
        assert replay.status == 401
        assert "WWW-Authenticate" in replay.headers
        assert simulator.state.snapshot() == before
        simulator.state.update_motion(1.25)
        assert simulator.state.snapshot().position.pan == pytest.approx(0.5)
        assert not simulator.state.snapshot().velocity.moving


async def test_failed_soap_dispatch_still_consumes_digest_count(
    settings: Settings, digest_header: Callable[..., str]
) -> None:
    simulator = Simulator(settings)
    uri = "/onvif/device_service"
    nonce_match = re.search(r'nonce="([^"]+)"', simulator._http_digest.challenge())
    assert nonce_match is not None
    headers = {"Authorization": digest_header(nonce_match.group(1), uri=uri)}
    async with TestClient(TestServer(simulator.web_app)) as client:
        malformed = await client.post(uri, data=b"not SOAP", headers=headers)
        assert malformed.status == 400
        retry = await client.post(uri, data=SOAP_REQUEST, headers=headers)
        assert retry.status == 401
