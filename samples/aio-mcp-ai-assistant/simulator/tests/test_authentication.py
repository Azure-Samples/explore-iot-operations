from __future__ import annotations

import re
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor

import pytest

from onvif_simulator.authentication import DigestAuthenticator
from onvif_simulator.config import Settings


def nonce(authenticator: DigestAuthenticator) -> str:
    match = re.search(r'nonce="([^"]+)"', authenticator.challenge())
    assert match is not None
    return match.group(1)


def authorize(authenticator: DigestAuthenticator, settings: Settings, header: str) -> bool:
    return authenticator.authorize(
        header,
        method="POST",
        uri="/onvif/ptz_service",
        username=settings.camera_username,
        password=settings.camera_password.get_secret_value(),
    )


def test_counts_are_consumed_atomically_and_separate_clients_can_start_at_one(
    settings: Settings, digest_header: Callable[..., str]
) -> None:
    auth = DigestAuthenticator()
    current = nonce(auth)
    header = digest_header(current)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: authorize(auth, settings, header), range(2)))
    assert sorted(results) == [False, True]
    assert authorize(auth, settings, digest_header(current, nc="00000002"))
    assert not authorize(auth, settings, header)
    assert authorize(auth, settings, digest_header(current, cnonce="another-client"))


@pytest.mark.parametrize(
    "fields",
    [
        {"nc": "00000000"},
        {"nc": "1"},
        {"nc": "0000000g"},
        {"cnonce": ""},
        {"cnonce": "a" * 257},
        {"qop": None},
        {"qop": ""},
        {"qop": "auth-int"},
        {"method": "GET"},
        {"uri": "/another-endpoint"},
    ],
)
def test_invalid_headers_do_not_consume_a_counter(
    settings: Settings, digest_header: Callable[..., str], fields: dict[str, str | None]
) -> None:
    auth = DigestAuthenticator()
    current = nonce(auth)
    assert not authorize(auth, settings, digest_header(current, **fields))
    assert authorize(auth, settings, digest_header(current))


def test_bad_signature_cannot_advance_counter(
    settings: Settings, digest_header: Callable[..., str]
) -> None:
    auth = DigestAuthenticator()
    current = nonce(auth)
    forged = digest_header(current).replace("nc=00000001", "nc=ffffffff")
    assert not authorize(auth, settings, forged)
    assert authorize(auth, settings, digest_header(current))


def test_capacity_does_not_evict_active_replay_records(
    settings: Settings, digest_header: Callable[..., str]
) -> None:
    auth = DigestAuthenticator()
    current = nonce(auth)
    for index in range(1024):
        assert authorize(auth, settings, digest_header(current, cnonce=f"client-{index}"))
    assert not authorize(auth, settings, digest_header(current, cnonce="overflow"))
    assert not authorize(auth, settings, digest_header(current, cnonce="client-0"))
    assert authorize(auth, settings, digest_header(current, cnonce="client-0", nc="00000002"))


def test_expiry_rotates_nonce_without_reenabling_old_headers(
    settings: Settings, digest_header: Callable[..., str], monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = [0.0]
    monkeypatch.setattr("onvif_simulator.authentication.time.monotonic", lambda: clock[0])
    auth = DigestAuthenticator()
    old = nonce(auth)
    assert authorize(auth, settings, digest_header(old))
    clock[0] = 300.0
    assert not authorize(auth, settings, digest_header(old, nc="00000002"))
    new = nonce(auth)
    assert new != old
    assert authorize(auth, settings, digest_header(new))
    assert not authorize(auth, settings, digest_header(old))
