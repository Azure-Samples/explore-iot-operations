from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass

from onvif_simulator.config import Settings
from onvif_simulator.onvif.auth import UsernameTokenAuthenticator
from onvif_simulator.onvif.control_services import ControlServices
from onvif_simulator.onvif.device_media import DeviceMediaService
from onvif_simulator.onvif.xml import (
    SoapFaultError,
    fault_envelope,
    local_name,
    parse_soap,
    response_envelope,
)
from onvif_simulator.state import CameraState

PATH_SERVICES = {
    "/onvif/device_service": "device",
    "/onvif/media_service": "media",
    "/onvif/media2_service": "media2",
    "/onvif/ptz_service": "ptz",
    "/onvif/imaging_service": "imaging",
    "/onvif/events_service": "events",
    "/onvif/deviceio_service": "deviceio",
}
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class SoapResult:
    payload: bytes
    status: int


class OnvifDispatcher:
    def __init__(
        self,
        settings: Settings,
        state: CameraState,
        ptz_reporter: Callable[[str], None] | None = None,
    ) -> None:
        self._authenticator = UsernameTokenAuthenticator(settings)
        self._device_media = DeviceMediaService(settings)
        self._controls = ControlServices(settings, state, ptz_reporter)

    def dispatch(
        self,
        path: str,
        payload: bytes,
        action_header: str | None,
        *,
        transport_authenticated: bool = False,
    ) -> SoapResult:
        message_id: str | None = None
        try:
            request = parse_soap(payload, action_header)
            message_id = request.message_id
            service = PATH_SERVICES.get(path)
            if service is None:
                raise SoapFaultError("unknown ONVIF service endpoint", "ter:ActionNotSupported")
            action = local_name(request.operation)
            if not transport_authenticated and not (
                service == "device" and action == "GetSystemDateAndTime"
            ):
                self._authenticator.authenticate(request.envelope)

            if service == "device":
                response = self._device_media.handle_device(action, request.operation)
            elif service == "media":
                response = self._device_media.handle_media(action, request.operation)
            elif service == "media2":
                response = self._device_media.handle_media(action, request.operation, media2=True)
            elif service == "ptz":
                response = self._controls.handle_ptz(action, request.operation)
            elif service == "imaging":
                response = self._controls.handle_imaging(action, request.operation)
            elif service == "events":
                response = self._controls.handle_events(action, request.operation)
            else:
                response = self._controls.handle_deviceio(action, request.operation)
            return SoapResult(
                response_envelope(response, request.action, request.message_id),
                200,
            )
        except SoapFaultError as exc:
            status = 401 if exc.subcode == "ter:NotAuthorized" else 400
            return SoapResult(
                fault_envelope(exc.reason, exc.subcode, exc.code, message_id),
                status,
            )
        except Exception:
            LOGGER.exception("unhandled ONVIF request failure", extra={"path": path})
            return SoapResult(
                fault_envelope(
                    "internal simulator error",
                    "ter:InternalError",
                    "s:Receiver",
                    message_id,
                ),
                500,
            )
