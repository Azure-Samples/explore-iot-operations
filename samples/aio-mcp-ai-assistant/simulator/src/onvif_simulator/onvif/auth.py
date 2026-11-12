from __future__ import annotations

import base64
import hashlib
import hmac
from datetime import UTC, datetime, timedelta

from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.namespaces import SOAP, WSSE, WSU
from onvif_simulator.onvif.xml import SoapFaultError, qname

PASSWORD_DIGEST = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
)
PASSWORD_TEXT = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-username-token-profile-1.0#PasswordText"
)


class UsernameTokenAuthenticator:
    def __init__(self, settings: Settings, clock_skew_seconds: int = 300) -> None:
        self._settings = settings
        self._clock_skew = timedelta(seconds=clock_skew_seconds)
        self._seen: dict[str, datetime] = {}

    def authenticate(self, envelope: etree._Element) -> None:
        header = envelope.find(qname(SOAP, "Header"))
        security = header.find(qname(WSSE, "Security")) if header is not None else None
        token = security.find(qname(WSSE, "UsernameToken")) if security is not None else None
        if token is None:
            raise SoapFaultError("authentication is required", "ter:NotAuthorized")

        username_node = token.find(qname(WSSE, "Username"))
        password_node = token.find(qname(WSSE, "Password"))
        nonce_node = token.find(qname(WSSE, "Nonce"))
        created_node = token.find(qname(WSU, "Created"))
        username = username_node.text if username_node is not None else ""
        supplied = password_node.text if password_node is not None else ""
        password_type = (
            password_node.get("Type", PASSWORD_TEXT) if password_node is not None else ""
        )

        if not hmac.compare_digest(username, self._settings.camera_username):
            raise SoapFaultError("invalid camera credentials", "ter:NotAuthorized")

        if password_type.endswith("#PasswordText"):
            if not hmac.compare_digest(supplied, self._settings.camera_password.get_secret_value()):
                raise SoapFaultError("invalid camera credentials", "ter:NotAuthorized")
            return

        if not password_type.endswith("#PasswordDigest"):
            raise SoapFaultError("unsupported UsernameToken password type", "ter:NotAuthorized")
        if (
            nonce_node is None
            or created_node is None
            or not nonce_node.text
            or not created_node.text
        ):
            raise SoapFaultError(
                "digest authentication requires Nonce and Created",
                "ter:NotAuthorized",
            )

        try:
            nonce = base64.b64decode(nonce_node.text, validate=True)
            created = datetime.fromisoformat(created_node.text.replace("Z", "+00:00"))
            if created.tzinfo is None:
                created = created.replace(tzinfo=UTC)
        except (ValueError, TypeError) as exc:
            raise SoapFaultError(
                "invalid UsernameToken Nonce or Created",
                "ter:NotAuthorized",
            ) from exc

        now = datetime.now(UTC)
        if abs(now - created.astimezone(UTC)) > self._clock_skew:
            raise SoapFaultError(
                "UsernameToken timestamp is outside allowed skew",
                "ter:NotAuthorized",
            )

        replay_key = hashlib.sha256(nonce + created_node.text.encode()).hexdigest()
        self._purge_seen(now)
        if replay_key in self._seen:
            raise SoapFaultError("UsernameToken replay detected", "ter:NotAuthorized")

        expected = base64.b64encode(
            hashlib.sha1(  # noqa: S324 - WS-Security UsernameToken requires SHA-1.
                nonce
                + created_node.text.encode()
                + self._settings.camera_password.get_secret_value().encode()
            ).digest()
        ).decode()
        if not hmac.compare_digest(supplied, expected):
            raise SoapFaultError("invalid camera credentials", "ter:NotAuthorized")
        self._seen[replay_key] = now

    def _purge_seen(self, now: datetime) -> None:
        cutoff = now - self._clock_skew
        self._seen = {key: value for key, value in self._seen.items() if value >= cutoff}
