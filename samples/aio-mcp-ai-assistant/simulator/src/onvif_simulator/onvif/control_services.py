from __future__ import annotations

import re
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from lxml import etree

from onvif_simulator.config import Settings
from onvif_simulator.onvif.common import (
    PAN_POSITION_SPACE,
    PAN_SPEED_SPACE,
    PAN_TRANSLATION_SPACE,
    PAN_VELOCITY_SPACE,
    ZOOM_POSITION_SPACE,
    ZOOM_SPEED_SPACE,
    ZOOM_TRANSLATION_SPACE,
    ZOOM_VELOCITY_SPACE,
    add_float_range,
    add_ptz_configuration,
    add_space_1d,
    add_space_2d,
)
from onvif_simulator.onvif.namespaces import (
    TEV,
    TIMG,
    TIO,
    TPTZ,
    TT,
    WSA,
    WSNT,
    WSTOP,
)
from onvif_simulator.onvif.xml import (
    SoapFaultError,
    bool_text,
    child,
    child_text,
    element,
    float_attribute,
    qname,
)
from onvif_simulator.state import CameraState, PTZPosition, PTZVelocity

_DURATION_PATTERN = re.compile(
    r"^PT(?:(?P<hours>\d+(?:\.\d+)?)H)?"
    r"(?:(?P<minutes>\d+(?:\.\d+)?)M)?"
    r"(?:(?P<seconds>\d+(?:\.\d+)?)S)?$"
)
_DEFAULT_CONTINUOUS_MOVE_TIMEOUT_SECONDS = 60.0
_MAX_CONTINUOUS_MOVE_TIMEOUT_SECONDS = 60.0


def _ptz_timeout_seconds(value: str | None) -> float:
    if value is None:
        return _DEFAULT_CONTINUOUS_MOVE_TIMEOUT_SECONDS
    match = _DURATION_PATTERN.fullmatch(value.strip())
    if match is None or not any(match.groupdict().values()):
        raise SoapFaultError(
            f"invalid PTZ timeout {value!r}",
            "ter:InvalidArgVal",
        )
    seconds = (
        float(match.group("hours") or 0) * 3600
        + float(match.group("minutes") or 0) * 60
        + float(match.group("seconds") or 0)
    )
    if not 0 <= seconds <= _MAX_CONTINUOUS_MOVE_TIMEOUT_SECONDS:
        raise SoapFaultError(
            f"PTZ timeout must be between 0 and 60 seconds, got {value!r}",
            "ter:InvalidArgVal",
        )
    return seconds


class ControlServices:
    def __init__(
        self,
        settings: Settings,
        state: CameraState,
        ptz_reporter: Callable[[str], None] | None = None,
    ) -> None:
        self._settings = settings
        self._state = state
        self._ptz_reporter = ptz_reporter

    def _report_ptz(self, event: str) -> None:
        if self._ptz_reporter is not None:
            self._ptz_reporter(event)

    def handle_ptz(self, action: str, request: etree._Element) -> etree._Element:
        response = etree.Element(qname(TPTZ, f"{action}Response"))
        handler = getattr(self, f"_ptz_{action}", None)
        if handler is None:
            raise SoapFaultError(f"PTZ action {action} is not supported", "ter:ActionNotSupported")
        handler(response, request)
        return response

    def handle_imaging(self, action: str, request: etree._Element) -> etree._Element:
        response = etree.Element(qname(TIMG, f"{action}Response"))
        handler = getattr(self, f"_imaging_{action}", None)
        if handler is None:
            raise SoapFaultError(
                f"imaging action {action} is not supported", "ter:ActionNotSupported"
            )
        handler(response, request)
        return response

    def handle_events(self, action: str, request: etree._Element) -> etree._Element:
        response = etree.Element(qname(TEV, f"{action}Response"))
        handler = getattr(self, f"_events_{action}", None)
        if handler is None:
            raise SoapFaultError(
                f"events action {action} is not supported", "ter:ActionNotSupported"
            )
        handler(response, request)
        return response

    def handle_deviceio(self, action: str, request: etree._Element) -> etree._Element:
        response = etree.Element(qname(TIO, f"{action}Response"))
        handler = getattr(self, f"_deviceio_{action}", None)
        if handler is None:
            raise SoapFaultError(
                f"DeviceIO action {action} is not supported", "ter:ActionNotSupported"
            )
        handler(response, request)
        return response

    def _ptz_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        capabilities = element(response, TPTZ, "Capabilities")
        capabilities.set("EFlip", "false")
        capabilities.set("Reverse", "false")
        capabilities.set("GetCompatibleConfigurations", "true")
        capabilities.set("MoveStatus", "true")
        capabilities.set("StatusPosition", "true")

    def _ptz_GetNodes(self, response: etree._Element, request: etree._Element) -> None:
        self._add_node(response, "PTZNode")

    def _ptz_GetNode(self, response: etree._Element, request: etree._Element) -> None:
        self._require_token(request, "NodeToken", "ptz_node_1")
        self._add_node(response, "PTZNode")

    def _ptz_GetConfigurations(self, response: etree._Element, request: etree._Element) -> None:
        for profile in self._settings.profiles.values():
            add_ptz_configuration(
                response,
                profile,
                namespace=TPTZ,
                name="PTZConfiguration",
            )

    def _ptz_GetConfiguration(self, response: etree._Element, request: etree._Element) -> None:
        token = child_text(request, "PTZConfigurationToken", required=True) or ""
        profile_token = token.removeprefix("ptz_")
        try:
            profile = self._settings.profile_by_token(profile_token)
        except KeyError as exc:
            raise SoapFaultError(f"unknown PTZ configuration {token!r}") from exc
        add_ptz_configuration(
            response,
            profile,
            namespace=TPTZ,
            name="PTZConfiguration",
        )

    def _ptz_SetConfiguration(self, response: etree._Element, request: etree._Element) -> None:
        configuration = child(request, "PTZConfiguration", required=True)
        if configuration is None or not configuration.get("token"):
            raise SoapFaultError("PTZConfiguration token is required")

    def _ptz_GetConfigurationOptions(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        token = child_text(request, "ConfigurationToken", required=True) or ""
        if not token.startswith("ptz_"):
            raise SoapFaultError(f"unknown PTZ configuration {token!r}")
        spaces = element(response, TPTZ, "PTZConfigurationOptions")
        spaces_node = element(spaces, TT, "Spaces")
        add_space_2d(
            spaces_node,
            "AbsolutePanTiltPositionSpace",
            PAN_POSITION_SPACE,
            -1.0,
            1.0,
        )
        add_space_1d(
            spaces_node,
            "AbsoluteZoomPositionSpace",
            ZOOM_POSITION_SPACE,
            0.0,
            1.0,
        )
        add_space_2d(
            spaces_node,
            "RelativePanTiltTranslationSpace",
            PAN_TRANSLATION_SPACE,
            -1.0,
            1.0,
        )
        add_space_1d(
            spaces_node,
            "RelativeZoomTranslationSpace",
            ZOOM_TRANSLATION_SPACE,
            -1.0,
            1.0,
        )
        add_space_2d(
            spaces_node,
            "ContinuousPanTiltVelocitySpace",
            PAN_VELOCITY_SPACE,
            -1.0,
            1.0,
        )
        add_space_1d(
            spaces_node,
            "ContinuousZoomVelocitySpace",
            ZOOM_VELOCITY_SPACE,
            -1.0,
            1.0,
        )
        add_space_2d(spaces_node, "PanTiltSpeedSpace", PAN_SPEED_SPACE, 0.0, 1.0)
        add_space_1d(spaces_node, "ZoomSpeedSpace", ZOOM_SPEED_SPACE, 0.0, 1.0)
        timeout = element(spaces, TT, "PTZTimeout")
        element(timeout, TT, "Min", "PT0S")
        element(timeout, TT, "Max", "PT60S")

    def _ptz_GetStatus(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        snapshot = self._state.snapshot()
        status = element(response, TPTZ, "PTZStatus")
        position = element(status, TT, "Position")
        element(
            position,
            TT,
            "PanTilt",
            x=str(snapshot.position.pan),
            y=str(snapshot.position.tilt),
            space=PAN_POSITION_SPACE,
        )
        element(
            position,
            TT,
            "Zoom",
            x=str(snapshot.position.zoom),
            space=ZOOM_POSITION_SPACE,
        )
        move = element(status, TT, "MoveStatus")
        pan_moving = not (abs(snapshot.velocity.pan) < 1e-9 and abs(snapshot.velocity.tilt) < 1e-9)
        element(move, TT, "PanTilt", "MOVING" if pan_moving else "IDLE")
        element(move, TT, "Zoom", "MOVING" if abs(snapshot.velocity.zoom) >= 1e-9 else "IDLE")
        element(status, TT, "UtcTime", datetime.now(UTC).isoformat().replace("+00:00", "Z"))

    def _ptz_AbsoluteMove(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        position = child(request, "Position", required=True)
        pan_tilt = child(position, "PanTilt") if position is not None else None
        zoom = child(position, "Zoom") if position is not None else None
        current = self._state.snapshot().position
        self._state.absolute_move(
            PTZPosition(
                pan=float_attribute(pan_tilt, "x", current.pan),
                tilt=float_attribute(pan_tilt, "y", current.tilt),
                zoom=float_attribute(zoom, "x", current.zoom),
            )
        )
        self._report_ptz("absolute_move")

    def _ptz_RelativeMove(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        translation = child(request, "Translation", required=True)
        pan_tilt = child(translation, "PanTilt") if translation is not None else None
        zoom = child(translation, "Zoom") if translation is not None else None
        self._state.relative_move(
            PTZPosition(
                pan=float_attribute(pan_tilt, "x"),
                tilt=float_attribute(pan_tilt, "y"),
                zoom=float_attribute(zoom, "x"),
            )
        )
        self._report_ptz("relative_move")

    def _ptz_ContinuousMove(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        velocity = child(request, "Velocity", required=True)
        pan_tilt = child(velocity, "PanTilt") if velocity is not None else None
        zoom = child(velocity, "Zoom") if velocity is not None else None
        self._state.continuous_move(
            PTZVelocity(
                pan=float_attribute(pan_tilt, "x"),
                tilt=float_attribute(pan_tilt, "y"),
                zoom=float_attribute(zoom, "x"),
            ),
            timeout_seconds=_ptz_timeout_seconds(child_text(request, "Timeout")),
        )
        self._report_ptz("continuous_move_started")

    def _ptz_Stop(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        self._state.stop(
            pan_tilt=bool_text(child_text(request, "PanTilt"), True),
            zoom=bool_text(child_text(request, "Zoom"), True),
        )
        self._report_ptz("movement_stopped")

    def _ptz_SetHomePosition(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        self._state.set_home()
        self._report_ptz("home_position_set")

    def _ptz_GotoHomePosition(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        self._state.goto_home()
        self._report_ptz("goto_home")

    def _ptz_GetPresets(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        for preset in self._state.snapshot().presets:
            node = element(response, TPTZ, "Preset", token=preset.token)
            element(node, TT, "Name", preset.name)
            position = element(node, TT, "PTZPosition")
            element(
                position,
                TT,
                "PanTilt",
                x=str(preset.position.pan),
                y=str(preset.position.tilt),
                space=PAN_POSITION_SPACE,
            )
            element(
                position,
                TT,
                "Zoom",
                x=str(preset.position.zoom),
                space=ZOOM_POSITION_SPACE,
            )

    def _ptz_SetPreset(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        preset = self._state.set_preset(
            child_text(request, "PresetName"),
            child_text(request, "PresetToken"),
        )
        element(response, TPTZ, "PresetToken", preset.token)

    def _ptz_RemovePreset(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        token = child_text(request, "PresetToken", required=True) or ""
        try:
            self._state.remove_preset(token)
        except KeyError as exc:
            raise SoapFaultError(f"unknown preset token {token!r}", "ter:InvalidArgVal") from exc

    def _ptz_GotoPreset(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        token = child_text(request, "PresetToken", required=True) or ""
        try:
            self._state.goto_preset(token)
        except KeyError as exc:
            raise SoapFaultError(f"unknown preset token {token!r}", "ter:InvalidArgVal") from exc
        self._report_ptz("goto_preset")

    def _ptz_SendAuxiliaryCommand(self, response: etree._Element, request: etree._Element) -> None:
        self._require_profile(request)
        command = child_text(request, "AuxiliaryData", required=True) or ""
        if command not in {"tt:Wiper|On", "tt:Wiper|Off"}:
            raise SoapFaultError("unsupported auxiliary command", "ter:ActionNotSupported")
        element(response, TPTZ, "AuxiliaryResponse", command)

    def _imaging_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        capabilities = element(response, TIMG, "Capabilities")
        capabilities.set("ImageStabilization", "false")

    def _imaging_GetImagingSettings(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        self._require_video_source(request)
        settings = element(response, TIMG, "ImagingSettings")
        imaging = self._state.snapshot().imaging
        element(settings, TT, "Brightness", imaging.brightness)
        element(settings, TT, "ColorSaturation", imaging.color_saturation)
        element(settings, TT, "Contrast", imaging.contrast)
        element(settings, TT, "Sharpness", imaging.sharpness)

    def _imaging_SetImagingSettings(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        self._require_video_source(request)
        node = child(request, "ImagingSettings", required=True)
        field_names = {
            "Brightness": "brightness",
            "ColorSaturation": "color_saturation",
            "Contrast": "contrast",
            "Sharpness": "sharpness",
        }
        values: dict[str, float] = {}
        if node is not None:
            for xml_name, field_name in field_names.items():
                raw = child_text(node, xml_name)
                if raw is not None:
                    try:
                        values[field_name] = float(raw)
                    except ValueError as exc:
                        raise SoapFaultError(f"{xml_name} must be numeric") from exc
        self._state.set_imaging(**values)

    def _imaging_GetOptions(self, response: etree._Element, request: etree._Element) -> None:
        self._require_video_source(request)
        options = element(response, TIMG, "ImagingOptions")
        for name in ("Brightness", "ColorSaturation", "Contrast", "Sharpness"):
            add_float_range(options, name, 0.0, 100.0)

    def _imaging_GetStatus(self, response: etree._Element, request: etree._Element) -> None:
        self._require_video_source(request)
        status = element(response, TIMG, "Status")
        focus = element(status, TT, "FocusStatus20")
        element(focus, TT, "Position", 0.0)
        element(focus, TT, "MoveStatus", "IDLE")

    def _imaging_GetMoveOptions(self, response: etree._Element, request: etree._Element) -> None:
        self._require_video_source(request)
        element(response, TIMG, "MoveOptions")

    def _imaging_Move(self, response: etree._Element, request: etree._Element) -> None:
        self._require_video_source(request)

    def _imaging_Stop(self, response: etree._Element, request: etree._Element) -> None:
        self._require_video_source(request)

    def _events_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        capabilities = element(response, TEV, "Capabilities")
        capabilities.set("WSSubscriptionPolicySupport", "false")
        capabilities.set("WSPullPointSupport", "true")
        capabilities.set("WSPausableSubscriptionManagerInterfaceSupport", "false")
        capabilities.set("MaxPullPoints", "16")
        capabilities.set("PersistentNotificationStorage", "false")

    def _events_GetEventProperties(self, response: etree._Element, request: etree._Element) -> None:
        element(response, TEV, "TopicNamespaceLocation", "http://www.onvif.org/onvif/ver10/topics")
        topic_set = element(response, WSTOP, "TopicSet")
        simulator = element(topic_set, "http://www.onvif.org/ver10/topics", "Simulator")
        element(simulator, "http://www.onvif.org/ver10/topics", "ImageChanged")
        element(simulator, "http://www.onvif.org/ver10/topics", "PTZStatus")
        element(response, TEV, "FixedTopicSet", True)
        element(
            response,
            TEV,
            "TopicExpressionDialect",
            "http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet",
        )
        element(
            response,
            TEV,
            "MessageContentFilterDialect",
            "http://www.onvif.org/ver10/tev/messageContentFilter/ItemFilter",
        )
        element(
            response,
            TEV,
            "MessageContentSchemaLocation",
            "http://www.onvif.org/ver10/schema/onvif.xsd",
        )

    def _events_CreatePullPointSubscription(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        subscription = element(response, WSNT, "SubscriptionReference")
        element(
            subscription,
            WSA,
            "Address",
            f"{self._settings.http_base_url}/onvif/events_service",
        )
        now = datetime.now(UTC)
        element(response, WSNT, "CurrentTime", now.isoformat().replace("+00:00", "Z"))
        element(
            response,
            WSNT,
            "TerminationTime",
            (now + timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        )

    def _events_PullMessages(self, response: etree._Element, request: etree._Element) -> None:
        now = datetime.now(UTC)
        element(response, TEV, "CurrentTime", now.isoformat().replace("+00:00", "Z"))
        element(
            response,
            TEV,
            "TerminationTime",
            (now + timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        )

    def _events_Renew(self, response: etree._Element, request: etree._Element) -> None:
        now = datetime.now(UTC)
        element(
            response,
            WSNT,
            "TerminationTime",
            (now + timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        )
        element(response, WSNT, "CurrentTime", now.isoformat().replace("+00:00", "Z"))

    def _events_Unsubscribe(self, response: etree._Element, request: etree._Element) -> None:
        return

    def _events_SetSynchronizationPoint(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        return

    def _events_Seek(self, response: etree._Element, request: etree._Element) -> None:
        return

    def _deviceio_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        capabilities = element(response, TIO, "Capabilities")
        capabilities.set("VideoSources", "1")
        capabilities.set("VideoOutputs", "0")
        capabilities.set("AudioSources", "0")
        capabilities.set("AudioOutputs", "0")
        capabilities.set("RelayOutputs", "1")
        capabilities.set("DigitalInputs", "1")
        capabilities.set("SerialPorts", "0")

    def _deviceio_GetDigitalInputs(self, response: etree._Element, request: etree._Element) -> None:
        input_node = element(response, TIO, "DigitalInputs", token="input_1")
        input_node.set("IdleState", "open")

    def _deviceio_GetRelayOutputs(self, response: etree._Element, request: etree._Element) -> None:
        relay = element(response, TIO, "RelayOutputs", token="relay_1")
        properties = element(relay, TT, "Properties")
        element(properties, TT, "Mode", "Bistable")
        element(properties, TT, "DelayTime", "PT0S")
        element(properties, TT, "IdleState", "open")

    def _deviceio_SetRelayOutputState(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        self._require_token(request, "RelayOutputToken", "relay_1")
        state = child_text(request, "LogicalState", required=True)
        if state not in {"active", "inactive"}:
            raise SoapFaultError("LogicalState must be active or inactive")
        self._state.set_relay(state == "active")

    def _deviceio_GetVideoSources(self, response: etree._Element, request: etree._Element) -> None:
        largest = max(self._settings.profiles.values(), key=lambda item: item.width * item.height)
        source = element(response, TIO, "Token", "video_source_1")
        element(source, TT, "Framerate", largest.frame_rate)

    def _add_node(self, response: etree._Element, response_name: str) -> None:
        node = element(
            response,
            TPTZ,
            response_name,
            token="ptz_node_1",
            FixedHomePosition="false",
        )
        element(node, TT, "Name", "Digital PTZ")
        spaces = element(node, TT, "SupportedPTZSpaces")
        add_space_2d(spaces, "AbsolutePanTiltPositionSpace", PAN_POSITION_SPACE, -1.0, 1.0)
        add_space_1d(spaces, "AbsoluteZoomPositionSpace", ZOOM_POSITION_SPACE, 0.0, 1.0)
        add_space_2d(
            spaces,
            "RelativePanTiltTranslationSpace",
            PAN_TRANSLATION_SPACE,
            -1.0,
            1.0,
        )
        add_space_1d(
            spaces,
            "RelativeZoomTranslationSpace",
            ZOOM_TRANSLATION_SPACE,
            -1.0,
            1.0,
        )
        add_space_2d(
            spaces,
            "ContinuousPanTiltVelocitySpace",
            PAN_VELOCITY_SPACE,
            -1.0,
            1.0,
        )
        add_space_1d(
            spaces,
            "ContinuousZoomVelocitySpace",
            ZOOM_VELOCITY_SPACE,
            -1.0,
            1.0,
        )
        element(node, TT, "MaximumNumberOfPresets", 32)
        element(node, TT, "HomeSupported", True)

    def _require_profile(self, request: etree._Element) -> None:
        token = child_text(request, "ProfileToken", required=True) or ""
        try:
            self._settings.profile_by_token(token)
        except KeyError as exc:
            raise SoapFaultError(f"unknown profile token {token!r}", "ter:NoProfile") from exc

    @staticmethod
    def _require_video_source(request: etree._Element) -> None:
        token = child_text(request, "VideoSourceToken", required=True)
        if token != "video_source_1":
            raise SoapFaultError(f"unknown video source token {token!r}", "ter:InvalidArgVal")

    @staticmethod
    def _require_token(request: etree._Element, name: str, expected: str) -> None:
        token = child_text(request, name, required=True)
        if token != expected:
            raise SoapFaultError(f"unknown {name} {token!r}", "ter:InvalidArgVal")
