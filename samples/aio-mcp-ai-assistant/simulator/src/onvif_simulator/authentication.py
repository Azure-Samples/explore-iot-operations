from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import secrets
import threading
import time
from typing import Final

REALM: Final = "ONVIF Simulator"
AUTH_PARAMETER = re.compile(r'(\w+)=("([^"]*)"|([^,\s]+))')
LOGGER = logging.getLogger(__name__)


def is_basic_authorized(
    authorization: str,
    username: str,
    password: str,
) -> bool:
    scheme, separator, encoded = authorization.partition(" ")
    if not separator or scheme.lower() != "basic":
        return False
    try:
        decoded = base64.b64decode(encoded, validate=True).decode()
    except (ValueError, UnicodeDecodeError):
        return False
    return hmac.compare_digest(decoded, f"{username}:{password}")


class DigestAuthenticator:
    """Consume increasing qop=auth counts for one bounded, expiring server nonce."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._nonce = secrets.token_hex(16)
        self._expires_at = time.monotonic() + 300
        self._counts: dict[tuple[str, str], int] = {}

    def _expire(self) -> None:
        now = time.monotonic()
        if now >= self._expires_at:
            self._nonce = secrets.token_hex(16)
            self._expires_at = now + 300
            self._counts.clear()

    def challenge(self) -> str:
        with self._lock:
            self._expire()
            return f'Digest realm="{REALM}", nonce="{self._nonce}", algorithm=MD5, qop="auth"'

    def authorize(
        self,
        authorization: str,
        *,
        method: str,
        uri: str,
        username: str,
        password: str,
    ) -> bool:
        scheme, separator, encoded = authorization.partition(" ")
        if not separator or scheme.lower() != "digest" or len(authorization) > 8192:
            return False
        parameters: dict[str, str] = {}
        for match in AUTH_PARAMETER.finditer(encoded):
            name = match.group(1).lower()
            if name in parameters:
                return False
            parameters[name] = match.group(3) or match.group(4) or ""
        count = parameters.get("nc", "")
        client_nonce = parameters.get("cnonce", "")
        response = parameters.get("response", "")
        if (
            parameters.get("username") != username
            or parameters.get("realm") != REALM
            or parameters.get("uri") != uri
            or parameters.get("algorithm", "MD5").upper() != "MD5"
            or parameters.get("qop") != "auth"
            or not re.fullmatch(r"[0-9a-fA-F]{8}", count)
            or int(count, 16) == 0
            or not 1 <= len(client_nonce) <= 256
            or not re.fullmatch(r"[0-9a-fA-F]{32}", response)
        ):
            return False

        with self._lock:
            self._expire()
            if parameters.get("nonce") != self._nonce:
                return False
            ha1 = _md5(f"{username}:{REALM}:{password}")
            ha2 = _md5(f"{method}:{uri}")
            expected = _md5(f"{ha1}:{self._nonce}:{count}:{client_nonce}:auth:{ha2}")
            if not hmac.compare_digest(response.lower(), expected):
                return False
            key = (username, client_nonce)
            if int(count, 16) <= self._counts.get(key, 0):
                return False
            if key not in self._counts and len(self._counts) >= 1024:
                LOGGER.warning(
                    "Digest client limit reached; new clients must wait for nonce expiry"
                )
                return False
            # Consume before dispatch, including requests whose SOAP operation later fails.
            self._counts[key] = int(count, 16)
            return True


def _md5(value: str) -> str:
    return hashlib.md5(  # noqa: S324 - HTTP and RTSP Digest require MD5.
        value.encode()
    ).hexdigest()
