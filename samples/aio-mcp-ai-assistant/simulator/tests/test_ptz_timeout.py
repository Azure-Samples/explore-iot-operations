from __future__ import annotations

import pytest
from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.control_services import ControlServices
from onvif_simulator.onvif.namespaces import TPTZ, TT
from onvif_simulator.onvif.xml import SoapFaultError, element, qname
from onvif_simulator.state import CameraState, PTZVelocity


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


@pytest.mark.parametrize(
    "velocity,pan_tilt,zoom",
    [
        (PTZVelocity(pan=0.2), False, True),
        (PTZVelocity(zoom=0.2), True, False),
        (PTZVelocity(pan=0.2, tilt=0.2, zoom=0.2), False, True),
        (PTZVelocity(pan=0.2, tilt=0.2, zoom=0.2), True, False),
        (PTZVelocity(pan=0.2, zoom=0.2), False, False),
        (PTZVelocity(pan=0.2, zoom=0.2), True, True),
    ],
)
def test_selective_stop_preserves_original_deadline_for_remaining_axes(
    settings: Settings, velocity: PTZVelocity, pan_tilt: bool, zoom: bool
) -> None:
    state = CameraState(settings.state_path)
    services = ControlServices(settings, state)
    state.continuous_move(velocity, timeout_seconds=1.0)
    state.update_motion(0.25)
    request = etree.Element(qname(TPTZ, "Stop"))
    element(request, TPTZ, "ProfileToken", "profile_high")
    element(request, TPTZ, "PanTilt", str(pan_tilt).lower())
    element(request, TPTZ, "Zoom", str(zoom).lower())
    services.handle_ptz("Stop", request)
    assert state.snapshot().velocity == PTZVelocity(
        pan=0.0 if pan_tilt else velocity.pan,
        tilt=0.0 if pan_tilt else velocity.tilt,
        zoom=0.0 if zoom else velocity.zoom,
    )
    state.update_motion(1.0)
    snapshot = state.snapshot()
    assert snapshot.position.pan == pytest.approx(velocity.pan * (0.25 if pan_tilt else 1))
    assert snapshot.position.tilt == pytest.approx(velocity.tilt * (0.25 if pan_tilt else 1))
    assert snapshot.position.zoom == pytest.approx(velocity.zoom * (0.25 if zoom else 1))
    assert not snapshot.velocity.moving
