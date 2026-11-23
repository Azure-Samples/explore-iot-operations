SOAP = "http://www.w3.org/2003/05/soap-envelope"
WSA = "http://www.w3.org/2005/08/addressing"
WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
WSU = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
TT = "http://www.onvif.org/ver10/schema"
TDS = "http://www.onvif.org/ver10/device/wsdl"
TRT = "http://www.onvif.org/ver10/media/wsdl"
TR2 = "http://www.onvif.org/ver20/media/wsdl"
TPTZ = "http://www.onvif.org/ver20/ptz/wsdl"
TIMG = "http://www.onvif.org/ver20/imaging/wsdl"
TEV = "http://www.onvif.org/ver10/events/wsdl"
TIO = "http://www.onvif.org/ver10/deviceIO/wsdl"
TDN = "http://www.onvif.org/ver10/network/wsdl"
TER = "http://www.onvif.org/ver10/error"
WSNT = "http://docs.oasis-open.org/wsn/b-2"
WSTOP = "http://docs.oasis-open.org/wsn/t-1"
WSD = "http://schemas.xmlsoap.org/ws/2005/04/discovery"
XSD = "http://www.w3.org/2001/XMLSchema"
XSI = "http://www.w3.org/2001/XMLSchema-instance"

NSMAP = {
    "s": SOAP,
    "wsa": WSA,
    "wsse": WSSE,
    "wsu": WSU,
    "tt": TT,
    "tds": TDS,
    "trt": TRT,
    "tr2": TR2,
    "tptz": TPTZ,
    "timg": TIMG,
    "tev": TEV,
    "tio": TIO,
    "tdn": TDN,
    "ter": TER,
    "wsnt": WSNT,
    "wstop": WSTOP,
    "wsd": WSD,
    "xsd": XSD,
    "xsi": XSI,
}

SERVICE_NAMESPACES = {
    "device": TDS,
    "media": TRT,
    "media2": TR2,
    "ptz": TPTZ,
    "imaging": TIMG,
    "events": TEV,
    "deviceio": TIO,
}
