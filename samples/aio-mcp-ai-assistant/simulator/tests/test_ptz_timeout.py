from __future__ import annotations

import pytest
from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.control_services import ControlServices
from onvif_simulator.onvif.namespaces import TPTZ, TT
from onvif_simulator.onvif.xml import SoapFaultError, element, qname
from onvif_simulator.state import CameraState


def _continuous_move_request(timeout: str) -> etree._Element:
    request = etree.Element(qname(TPTZ, "ContinuousMove"))
    element(request, TPTZ, "ProfileToken", "profile_high")
    velocity = element(request, TPTZ, "Velocity")
    element(velocity, TT, "PanTilt", x="0.5", y="0.0")
    element(request, TPTZ, "Timeout", timeout)
    return request


def test_continuous_move_stops_at_requested_timeout(settings: Settings) -> None:
    state = CameraState(settings.state_path)
    services = ControlServices(settings, state)

    services.handle_ptz(
        "ContinuousMove",
        _continuous_move_request("PT1S"),
    )
    state.update_motion(0.75)
    state.update_motion(0.5)

    snapshot = state.snapshot()
    assert snapshot.position.pan == pytest.approx(0.5)
    assert snapshot.velocity.moving is False


def test_continuous_move_rejects_timeout_above_advertised_max(
    settings: Settings,
) -> None:
    state = CameraState(settings.state_path)
    services = ControlServices(settings, state)

    with pytest.raises(SoapFaultError, match="between 0 and 60 seconds"):
        services.handle_ptz(
            "ContinuousMove",
            _continuous_move_request("PT61S"),
        )
