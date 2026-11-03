from __future__ import annotations

import base64
import hashlib
import re

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


async def test_soap_supports_http_digest_authentication(settings: Settings) -> None:
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

        nonce = nonce_match.group(1)
        nc = "00000001"
        cnonce = "test-client"
        ha1 = hashlib.md5(  # noqa: S324 - HTTP Digest requires MD5.
            f"{settings.camera_username}:{REALM}:{settings.camera_password.get_secret_value()}".encode()
        ).hexdigest()
        ha2 = hashlib.md5(  # noqa: S324 - HTTP Digest requires MD5.
            f"POST:{uri}".encode()
        ).hexdigest()
        response = hashlib.md5(  # noqa: S324 - HTTP Digest requires MD5.
            f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}".encode()
        ).hexdigest()
        authorization = (
            f'Digest username="{settings.camera_username}", realm="{REALM}", '
            f'nonce="{nonce}", uri="{uri}", response="{response}", '
            f'algorithm=MD5, qop=auth, nc={nc}, cnonce="{cnonce}"'
        )
        accepted = await client.post(
            uri,
            data=SOAP_REQUEST,
            headers={**headers, "Authorization": authorization},
        )

        assert accepted.status == 200
        assert b"GetDeviceInformationResponse" in await accepted.read()
