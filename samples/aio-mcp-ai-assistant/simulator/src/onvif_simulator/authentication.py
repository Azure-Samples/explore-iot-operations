from __future__ import annotations

import base64
import hashlib
import hmac
import re
from typing import Final

REALM: Final = "ONVIF Simulator"
AUTH_PARAMETER = re.compile(r'(\w+)=("([^"]*)"|([^,\s]+))')


def digest_challenge(nonce: str) -> str:
    return f'Digest realm="{REALM}", nonce="{nonce}", algorithm=MD5, qop="auth"'


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


def is_digest_authorized(
    authorization: str,
    *,
    method: str,
    uri: str,
    nonce: str,
    username: str,
    password: str,
) -> bool:
    scheme, separator, encoded = authorization.partition(" ")
    if not separator or scheme.lower() != "digest":
        return False
    parameters = {
        match.group(1).lower(): match.group(3) or match.group(4) or ""
        for match in AUTH_PARAMETER.finditer(encoded)
    }
    if (
        parameters.get("username") != username
        or parameters.get("realm") != REALM
        or parameters.get("nonce") != nonce
        or parameters.get("uri") != uri
        or parameters.get("algorithm", "MD5").upper() != "MD5"
    ):
        return False

    ha1 = _md5(f"{username}:{REALM}:{password}")
    ha2 = _md5(f"{method}:{uri}")
    qop = parameters.get("qop")
    if qop:
        if qop.lower() != "auth" or not parameters.get("nc") or not parameters.get("cnonce"):
            return False
        expected = _md5(f"{ha1}:{nonce}:{parameters['nc']}:{parameters['cnonce']}:{qop}:{ha2}")
    else:
        expected = _md5(f"{ha1}:{nonce}:{ha2}")
    return hmac.compare_digest(parameters.get("response", ""), expected)


def _md5(value: str) -> str:
    return hashlib.md5(  # noqa: S324 - HTTP and RTSP Digest require MD5.
        value.encode()
    ).hexdigest()
