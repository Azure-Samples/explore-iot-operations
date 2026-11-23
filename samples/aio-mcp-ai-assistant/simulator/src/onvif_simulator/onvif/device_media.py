from __future__ import annotations

from datetime import UTC, datetime

from lxml import etree

from onvif_simulator.config import Settings, StreamProfile
from onvif_simulator.onvif.common import (
    add_float_range,
    add_profile,
    add_profile2,
    add_ptz_configuration,
    add_video_encoder2_configuration,
    add_video_encoder_configuration,
    add_video_source_configuration,
    profile_uri,
)
from onvif_simulator.onvif.namespaces import (
    TDS,
    TEV,
    TIMG,
    TIO,
    TPTZ,
    TR2,
    TRT,
    TT,
)
from onvif_simulator.onvif.xml import SoapFaultError, child_text, element, qname


class DeviceMediaService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def handle_device(self, action: str, request: etree._Element) -> etree._Element:
        response = etree.Element(qname(TDS, f"{action}Response"))
        handler = getattr(self, f"_device_{action}", None)
        if handler is None:
            if action.startswith(("Set", "Add", "Remove", "Create", "Delete")):
                return response
            raise SoapFaultError(
                f"device action {action} is not supported",
                "ter:ActionNotSupported",
            )
        handler(response, request)
        return response

    def handle_media(
        self,
        action: str,
        request: etree._Element,
        *,
        media2: bool = False,
    ) -> etree._Element:
        namespace = TR2 if media2 else TRT
        response = etree.Element(qname(namespace, f"{action}Response"))
        handler = getattr(self, f"_media_{action}", None)
        if handler is None:
            if action.startswith(("Set", "Add", "Remove", "Start", "Stop")):
                return response
            raise SoapFaultError(
                f"media action {action} is not supported",
                "ter:ActionNotSupported",
            )
        handler(response, request, namespace)
        return response

    def _device_GetSystemDateAndTime(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        now = datetime.now(UTC)
        system = element(response, TDS, "SystemDateAndTime")
        element(system, TT, "DateTimeType", "NTP")
        element(system, TT, "DaylightSavings", False)
        timezone = element(system, TT, "TimeZone")
        element(timezone, TT, "TZ", "UTC0")
        utc_time = element(system, TT, "UTCDateTime")
        self._add_datetime(utc_time, now)
        local_time = element(system, TT, "LocalDateTime")
        self._add_datetime(local_time, now)

    def _device_GetDeviceInformation(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        element(response, TDS, "Manufacturer", self._settings.manufacturer)
        element(response, TDS, "Model", self._settings.model)
        element(response, TDS, "FirmwareVersion", self._settings.firmware_version)
        element(response, TDS, "SerialNumber", self._settings.serial_number)
        element(response, TDS, "HardwareId", self._settings.hardware_id)

    def _device_GetServices(self, response: etree._Element, request: etree._Element) -> None:
        services = (
            (TDS, "/onvif/device_service", 2, 6),
            (TRT, "/onvif/media_service", 2, 6),
            (TR2, "/onvif/media2_service", 2, 0),
            (TPTZ, "/onvif/ptz_service", 2, 6),
            (TIMG, "/onvif/imaging_service", 2, 6),
            (TEV, "/onvif/events_service", 2, 6),
            (TIO, "/onvif/deviceio_service", 2, 6),
        )
        for namespace, path, major, minor in services:
            service = element(response, TDS, "Service")
            element(service, TDS, "Namespace", namespace)
            element(service, TDS, "XAddr", f"{self._settings.http_base_url}{path}")
            version = element(service, TDS, "Version")
            element(version, TT, "Major", major)
            element(version, TT, "Minor", minor)

    def _device_GetCapabilities(self, response: etree._Element, request: etree._Element) -> None:
        capabilities = element(response, TDS, "Capabilities")
        device = element(capabilities, TT, "Device")
        element(device, TT, "XAddr", f"{self._settings.http_base_url}/onvif/device_service")
        network = element(device, TT, "Network")
        element(network, TT, "IPFilter", False)
        element(network, TT, "ZeroConfiguration", False)
        element(network, TT, "IPVersion6", False)
        element(network, TT, "DynDNS", False)
        system = element(device, TT, "System")
        element(system, TT, "DiscoveryResolve", self._settings.discovery_enabled)
        element(system, TT, "DiscoveryBye", self._settings.discovery_enabled)
        element(system, TT, "RemoteDiscovery", False)
        element(system, TT, "SystemBackup", False)
        element(system, TT, "SystemLogging", True)
        element(system, TT, "FirmwareUpgrade", False)
        version = element(system, TT, "SupportedVersions")
        element(version, TT, "Major", 2)
        element(version, TT, "Minor", 6)
        io = element(device, TT, "IO")
        element(io, TT, "InputConnectors", 1)
        element(io, TT, "RelayOutputs", 1)
        security = element(device, TT, "Security")
        element(security, TT, "TLS1.1", False)
        element(security, TT, "TLS1.2", False)
        element(security, TT, "OnboardKeyGeneration", False)
        element(security, TT, "AccessPolicyConfig", False)
        element(security, TT, "X.509Token", False)
        element(security, TT, "SAMLToken", False)
        element(security, TT, "KerberosToken", False)
        element(security, TT, "RELToken", False)

        events = element(capabilities, TT, "Events")
        element(events, TT, "XAddr", f"{self._settings.http_base_url}/onvif/events_service")
        element(events, TT, "WSSubscriptionPolicySupport", False)
        element(events, TT, "WSPullPointSupport", True)
        element(events, TT, "WSPausableSubscriptionManagerInterfaceSupport", False)
        imaging = element(capabilities, TT, "Imaging")
        element(imaging, TT, "XAddr", f"{self._settings.http_base_url}/onvif/imaging_service")
        media = element(capabilities, TT, "Media")
        element(media, TT, "XAddr", f"{self._settings.http_base_url}/onvif/media_service")
        streaming = element(media, TT, "StreamingCapabilities")
        element(streaming, TT, "RTPMulticast", False)
        element(streaming, TT, "RTP_TCP", True)
        element(streaming, TT, "RTP_RTSP_TCP", True)
        ptz = element(capabilities, TT, "PTZ")
        element(ptz, TT, "XAddr", f"{self._settings.http_base_url}/onvif/ptz_service")

    def _device_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        capabilities = element(response, TDS, "Capabilities")
        capabilities.set("NetworkIPFilter", "false")
        capabilities.set("NetworkZeroConfiguration", "false")
        capabilities.set("SecurityUsernameToken", "true")
        capabilities.set("SecurityHttpDigest", "true")
        capabilities.set("SystemDiscoveryResolve", str(self._settings.discovery_enabled).lower())
        capabilities.set("SystemDiscoveryBye", str(self._settings.discovery_enabled).lower())
        capabilities.set("SystemBackup", "false")
        capabilities.set("SystemLogging", "true")
        capabilities.set("FirmwareUpgrade", "false")

    def _device_GetScopes(self, response: etree._Element, request: etree._Element) -> None:
        scopes = (
            ("Fixed", "onvif://www.onvif.org/type/video_encoder"),
            ("Fixed", "onvif://www.onvif.org/Profile/Streaming"),
            ("Fixed", "onvif://www.onvif.org/Profile/T"),
            ("Configurable", "onvif://www.onvif.org/name/AIO_ONVIF_Simulator"),
            ("Configurable", "onvif://www.onvif.org/location/AIO_Cluster"),
        )
        for definition, item in scopes:
            scope = element(response, TDS, "Scopes")
            element(scope, TT, "ScopeDef", definition)
            element(scope, TT, "ScopeItem", item)

    def _device_GetHostname(self, response: etree._Element, request: etree._Element) -> None:
        information = element(response, TDS, "HostnameInformation")
        element(information, TT, "FromDHCP", False)
        element(information, TT, "Name", self._settings.advertised_host)

    def _device_GetDNS(self, response: etree._Element, request: etree._Element) -> None:
        information = element(response, TDS, "DNSInformation")
        element(information, TT, "FromDHCP", True)

    def _device_GetNTP(self, response: etree._Element, request: etree._Element) -> None:
        information = element(response, TDS, "NTPInformation")
        element(information, TT, "FromDHCP", True)

    def _device_GetNetworkInterfaces(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        interface = element(response, TDS, "NetworkInterfaces", token="eth0")
        element(interface, TT, "Enabled", True)
        info = element(interface, TT, "Info")
        element(info, TT, "Name", "eth0")
        element(info, TT, "HwAddress", "02:00:00:00:00:01")
        ipv4 = element(interface, TT, "IPv4")
        element(ipv4, TT, "Enabled", True)
        config = element(ipv4, TT, "Config")
        element(config, TT, "DHCP", True)

    def _device_GetNetworkProtocols(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        for name, port in (("HTTP", self._settings.advertised_http_port), ("RTSP", 554)):
            protocol = element(response, TDS, "NetworkProtocols")
            element(protocol, TT, "Name", name)
            element(protocol, TT, "Enabled", True)
            element(protocol, TT, "Port", port)

    def _device_GetNetworkDefaultGateway(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        element(response, TDS, "NetworkGateway")

    def _device_GetUsers(self, response: etree._Element, request: etree._Element) -> None:
        user = element(response, TDS, "User")
        element(user, TT, "Username", "cameraadmin")
        element(user, TT, "UserLevel", "Administrator")

    def _device_GetWsdlUrl(self, response: etree._Element, request: etree._Element) -> None:
        element(response, TDS, "WsdlUrl", "https://www.onvif.org/profiles/specifications/")

    def _device_GetEndpointReference(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        element(response, TDS, "GUID", f"urn:uuid:{self._settings.serial_number}")

    def _device_GetDiscoveryMode(self, response: etree._Element, request: etree._Element) -> None:
        element(response, TDS, "DiscoveryMode", "Discoverable")

    def _device_GetSystemLog(self, response: etree._Element, request: etree._Element) -> None:
        log = element(response, TDS, "SystemLog")
        element(log, TT, "String", "ONVIF simulator is healthy")

    def _device_GetSupportInformation(
        self, response: etree._Element, request: etree._Element
    ) -> None:
        info = element(response, TDS, "SupportInformation")
        element(info, TT, "String", "Azure IoT Operations ONVIF simulator")

    def _device_SystemReboot(self, response: etree._Element, request: etree._Element) -> None:
        element(response, TDS, "Message", "Simulator reboot acknowledged")

    def _media_GetServiceCapabilities(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        capabilities = element(response, namespace, "Capabilities")
        capabilities.set("SnapshotUri", "true")
        capabilities.set("Rotation", "false")
        capabilities.set("VideoSourceMode", "false")
        capabilities.set("OSD", "false")
        capabilities.set("TemporaryOSDText", "false")
        profile = element(capabilities, namespace, "ProfileCapabilities")
        profile.set("MaximumNumberOfProfiles", str(len(self._settings.profiles)))
        streaming = element(capabilities, namespace, "StreamingCapabilities")
        streaming.set("RTPMulticast", "false")
        streaming.set("RTP_TCP", "true")
        streaming.set("RTP_RTSP_TCP", "true")
        streaming.set("NonAggregateControl", "true")
        streaming.set("NoRTSPStreaming", "false")

    def _media_GetProfiles(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            if namespace == TR2:
                add_profile2(response, profile, namespace=namespace)
            else:
                add_profile(response, profile, namespace=namespace, name="Profiles")

    def _media_GetProfile(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        profile = self._requested_profile(request)
        if namespace == TR2:
            add_profile2(response, profile, namespace=namespace)
        else:
            add_profile(response, profile, namespace=namespace, name="Profile")

    def _media_GetVideoSources(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        largest = max(self._settings.profiles.values(), key=lambda item: item.width * item.height)
        source_name = "VideoSources" if namespace == TRT else "VideoSources"
        source = element(response, namespace, source_name, token="video_source_1")
        element(source, TT, "Framerate", largest.frame_rate)
        resolution = element(source, TT, "Resolution")
        element(resolution, TT, "Width", largest.width)
        element(resolution, TT, "Height", largest.height)

    def _media_GetVideoSourceConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            add_video_source_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configurations",
            )

    def _media_GetVideoSourceConfiguration(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        profile = self._profile_from_configuration(request, "ConfigurationToken", "vsc_")
        add_video_source_configuration(
            response,
            profile,
            namespace=namespace,
            name="Configuration",
        )

    def _media_GetVideoEncoderConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            if namespace == TR2:
                add_video_encoder2_configuration(
                    response,
                    profile,
                    namespace=namespace,
                    name="Configurations",
                )
            else:
                add_video_encoder_configuration(
                    response,
                    profile,
                    namespace=namespace,
                    name="Configurations",
                )

    def _media_GetVideoEncoderConfiguration(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        profile = self._profile_from_configuration(request, "ConfigurationToken", "vec_")
        if namespace == TR2:
            add_video_encoder2_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configuration",
            )
        else:
            add_video_encoder_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configuration",
            )

    def _media_GetCompatibleVideoEncoderConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            add_video_encoder_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configurations",
            )

    def _media_GetCompatibleVideoSourceConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            add_video_source_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configurations",
            )

    def _media_GetVideoEncoderConfigurationOptions(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        options = element(response, namespace, "Options")
        h264 = element(options, TT, "H264")
        for profile in self._settings.profiles.values():
            resolution = element(h264, TT, "ResolutionsAvailable")
            element(resolution, TT, "Width", profile.width)
            element(resolution, TT, "Height", profile.height)
        add_float_range(h264, "QualityRange", 1.0, 10.0)
        element(h264, TT, "GovLengthRange")
        gov = h264[-1]
        element(gov, TT, "Min", 1)
        element(gov, TT, "Max", 600)
        frame = element(h264, TT, "FrameRateRange")
        element(frame, TT, "Min", 1)
        element(frame, TT, "Max", 60)
        interval = element(h264, TT, "EncodingIntervalRange")
        element(interval, TT, "Min", 1)
        element(interval, TT, "Max", 1)
        element(h264, TT, "H264ProfilesSupported", "Baseline")
        element(h264, TT, "H264ProfilesSupported", "Main")

    def _media_GetVideoSourceConfigurationOptions(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        largest = max(self._settings.profiles.values(), key=lambda item: item.width * item.height)
        options = element(response, namespace, "Options")
        bounds = element(options, TT, "BoundsRange")
        for name, minimum, maximum in (
            ("XRange", 0, 0),
            ("YRange", 0, 0),
            ("WidthRange", largest.width, largest.width),
            ("HeightRange", largest.height, largest.height),
        ):
            range_node = element(bounds, TT, name)
            element(range_node, TT, "Min", minimum)
            element(range_node, TT, "Max", maximum)
        element(options, TT, "VideoSourceTokensAvailable", "video_source_1")

    def _media_GetStreamUri(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        profile = self._requested_profile(request)
        if namespace == TR2:
            element(response, namespace, "Uri", profile_uri(self._settings, profile))
            return
        media_uri = element(response, namespace, "MediaUri")
        element(media_uri, TT, "Uri", profile_uri(self._settings, profile))
        element(media_uri, TT, "InvalidAfterConnect", False)
        element(media_uri, TT, "InvalidAfterReboot", False)
        element(media_uri, TT, "Timeout", "PT60S")

    def _media_GetSnapshotUri(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        profile = self._requested_profile(request)
        uri = f"{self._settings.http_base_url}/onvif/snapshot/{profile.token}.jpg"
        if namespace == TR2:
            element(response, namespace, "Uri", uri)
            return
        media_uri = element(response, namespace, "MediaUri")
        element(media_uri, TT, "Uri", uri)
        element(media_uri, TT, "InvalidAfterConnect", False)
        element(media_uri, TT, "InvalidAfterReboot", False)
        element(media_uri, TT, "Timeout", "PT60S")

    def _media_GetPTZConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        for profile in self._settings.profiles.values():
            add_ptz_configuration(
                response,
                profile,
                namespace=namespace,
                name="Configurations",
            )

    def _media_GetMetadataConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        return

    def _media_GetAudioSources(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        return

    def _media_GetAudioEncoderConfigurations(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        return

    def _media_GetGuaranteedNumberOfVideoEncoderInstances(
        self, response: etree._Element, request: etree._Element, namespace: str
    ) -> None:
        element(response, namespace, "TotalNumber", len(self._settings.profiles))
        element(response, namespace, "H264", len(self._settings.profiles))
        element(response, namespace, "JPEG", 0)
        element(response, namespace, "MPEG4", 0)

    def _requested_profile(self, request: etree._Element) -> StreamProfile:
        token = child_text(request, "ProfileToken", required=True)
        try:
            return self._settings.profile_by_token(token or "")
        except KeyError as exc:
            raise SoapFaultError(f"unknown profile token {token!r}", "ter:NoProfile") from exc

    def _profile_from_configuration(
        self,
        request: etree._Element,
        element_name: str,
        prefix: str,
    ) -> StreamProfile:
        token = child_text(request, element_name, required=True) or ""
        profile_token = token.removeprefix(prefix)
        try:
            return self._settings.profile_by_token(profile_token)
        except KeyError as exc:
            raise SoapFaultError(
                f"unknown configuration token {token!r}", "ter:InvalidArgVal"
            ) from exc

    @staticmethod
    def _add_datetime(parent: etree._Element, value: datetime) -> None:
        time = element(parent, TT, "Time")
        element(time, TT, "Hour", value.hour)
        element(time, TT, "Minute", value.minute)
        element(time, TT, "Second", value.second)
        date = element(parent, TT, "Date")
        element(date, TT, "Year", value.year)
        element(date, TT, "Month", value.month)
        element(date, TT, "Day", value.day)
