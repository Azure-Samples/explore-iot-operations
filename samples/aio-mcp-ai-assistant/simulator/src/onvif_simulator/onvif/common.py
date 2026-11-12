from __future__ import annotations

from lxml import etree

from onvif_simulator.config import Settings, StreamProfile
from onvif_simulator.onvif.namespaces import TT
from onvif_simulator.onvif.xml import element

PAN_POSITION_SPACE = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/PositionGenericSpace"
PAN_TRANSLATION_SPACE = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/TranslationGenericSpace"
PAN_VELOCITY_SPACE = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"
PAN_SPEED_SPACE = "http://www.onvif.org/ver10/tptz/PanTiltSpaces/GenericSpeedSpace"
ZOOM_POSITION_SPACE = "http://www.onvif.org/ver10/tptz/ZoomSpaces/PositionGenericSpace"
ZOOM_TRANSLATION_SPACE = "http://www.onvif.org/ver10/tptz/ZoomSpaces/TranslationGenericSpace"
ZOOM_VELOCITY_SPACE = "http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace"
ZOOM_SPEED_SPACE = "http://www.onvif.org/ver10/tptz/ZoomSpaces/ZoomGenericSpeedSpace"


def add_float_range(parent: etree._Element, name: str, minimum: float, maximum: float) -> None:
    range_node = element(parent, TT, name)
    element(range_node, TT, "Min", minimum)
    element(range_node, TT, "Max", maximum)


def add_space_2d(
    parent: etree._Element,
    name: str,
    uri: str,
    minimum: float,
    maximum: float,
) -> None:
    space = element(parent, TT, name)
    element(space, TT, "URI", uri)
    add_float_range(space, "XRange", minimum, maximum)
    add_float_range(space, "YRange", minimum, maximum)


def add_space_1d(
    parent: etree._Element,
    name: str,
    uri: str,
    minimum: float,
    maximum: float,
) -> None:
    space = element(parent, TT, name)
    element(space, TT, "URI", uri)
    add_float_range(space, "XRange", minimum, maximum)


def add_video_source_configuration(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str = TT,
    name: str = "VideoSourceConfiguration",
) -> None:
    configuration = element(parent, namespace, name, token=f"vsc_{profile.token}")
    element(configuration, TT, "Name", f"{profile.token} source")
    element(configuration, TT, "UseCount", 1)
    element(configuration, TT, "SourceToken", "video_source_1")
    element(
        configuration,
        TT,
        "Bounds",
        x="0",
        y="0",
        width=str(profile.width),
        height=str(profile.height),
    )


def add_video_encoder_configuration(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str = TT,
    name: str = "VideoEncoderConfiguration",
) -> None:
    configuration = element(parent, namespace, name, token=f"vec_{profile.token}")
    element(configuration, TT, "Name", f"{profile.token} H264")
    element(configuration, TT, "UseCount", 1)
    element(configuration, TT, "Encoding", "H264")
    resolution = element(configuration, TT, "Resolution")
    element(resolution, TT, "Width", profile.width)
    element(resolution, TT, "Height", profile.height)
    element(configuration, TT, "Quality", 5.0)
    rate = element(configuration, TT, "RateControl")
    element(rate, TT, "FrameRateLimit", profile.frame_rate)
    element(rate, TT, "EncodingInterval", 1)
    element(rate, TT, "BitrateLimit", profile.bitrate_kbps)
    h264 = element(configuration, TT, "H264")
    element(h264, TT, "GovLength", profile.key_frame_interval)
    element(h264, TT, "H264Profile", "Main")
    multicast = element(configuration, TT, "Multicast")
    address = element(multicast, TT, "Address")
    element(address, TT, "Type", "IPv4")
    element(address, TT, "IPv4Address", "0.0.0.0")
    element(multicast, TT, "Port", 0)
    element(multicast, TT, "TTL", 1)
    element(multicast, TT, "AutoStart", False)
    element(configuration, TT, "SessionTimeout", "PT60S")


def add_video_encoder2_configuration(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str,
    name: str,
) -> None:
    configuration = element(parent, namespace, name, token=f"vec_{profile.token}")
    element(configuration, TT, "Name", f"{profile.token} H264")
    element(configuration, TT, "UseCount", 1)
    element(configuration, TT, "Encoding", "H264")
    resolution = element(configuration, TT, "Resolution")
    element(resolution, TT, "Width", profile.width)
    element(resolution, TT, "Height", profile.height)
    rate = element(configuration, TT, "RateControl")
    element(rate, TT, "FrameRateLimit", profile.frame_rate)
    element(rate, TT, "BitrateLimit", profile.bitrate_kbps)
    element(configuration, TT, "GovLength", profile.key_frame_interval)
    element(configuration, TT, "Profile", "Main")
    element(configuration, TT, "Quality", 5.0)
    multicast = element(configuration, TT, "Multicast")
    address = element(multicast, TT, "Address")
    element(address, TT, "Type", "IPv4")
    element(address, TT, "IPv4Address", "0.0.0.0")
    element(multicast, TT, "Port", 0)
    element(multicast, TT, "TTL", 1)
    element(multicast, TT, "AutoStart", False)


def add_ptz_configuration(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str = TT,
    name: str = "PTZConfiguration",
) -> None:
    configuration = element(parent, namespace, name, token=f"ptz_{profile.token}")
    element(configuration, TT, "Name", f"{profile.token} PTZ")
    element(configuration, TT, "UseCount", 1)
    element(configuration, TT, "NodeToken", "ptz_node_1")
    element(configuration, TT, "DefaultAbsolutePantTiltPositionSpace", PAN_POSITION_SPACE)
    element(configuration, TT, "DefaultAbsoluteZoomPositionSpace", ZOOM_POSITION_SPACE)
    element(configuration, TT, "DefaultRelativePanTiltTranslationSpace", PAN_TRANSLATION_SPACE)
    element(configuration, TT, "DefaultRelativeZoomTranslationSpace", ZOOM_TRANSLATION_SPACE)
    element(configuration, TT, "DefaultContinuousPanTiltVelocitySpace", PAN_VELOCITY_SPACE)
    element(configuration, TT, "DefaultContinuousZoomVelocitySpace", ZOOM_VELOCITY_SPACE)
    speed = element(configuration, TT, "DefaultPTZSpeed")
    element(speed, TT, "PanTilt", x="0.5", y="0.5", space=PAN_SPEED_SPACE)
    element(speed, TT, "Zoom", x="0.5", space=ZOOM_SPEED_SPACE)
    element(configuration, TT, "DefaultPTZTimeout", "PT60S")
    pan_limits = element(configuration, TT, "PanTiltLimits")
    add_space_2d(pan_limits, "Range", PAN_POSITION_SPACE, -1.0, 1.0)
    zoom_limits = element(configuration, TT, "ZoomLimits")
    add_space_1d(zoom_limits, "Range", ZOOM_POSITION_SPACE, 0.0, 1.0)


def add_profile(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str,
    name: str,
) -> etree._Element:
    profile_node = element(parent, namespace, name, token=profile.token, fixed="true")
    element(profile_node, TT, "Name", profile.token)
    add_video_source_configuration(profile_node, profile)
    add_video_encoder_configuration(profile_node, profile)
    add_ptz_configuration(profile_node, profile)
    return profile_node


def add_profile2(
    parent: etree._Element,
    profile: StreamProfile,
    *,
    namespace: str,
) -> etree._Element:
    profile_node = element(parent, namespace, "Profiles", token=profile.token, fixed="true")
    element(profile_node, namespace, "Name", profile.token)
    configurations = element(profile_node, namespace, "Configurations")
    add_video_source_configuration(
        configurations,
        profile,
        namespace=namespace,
        name="VideoSource",
    )
    add_video_encoder2_configuration(
        configurations,
        profile,
        namespace=namespace,
        name="VideoEncoder",
    )
    add_ptz_configuration(
        configurations,
        profile,
        namespace=namespace,
        name="PTZ",
    )
    return profile_node


def profile_uri(settings: Settings, profile: StreamProfile) -> str:
    return f"{settings.rtsp_base_url}/{profile.path}"
