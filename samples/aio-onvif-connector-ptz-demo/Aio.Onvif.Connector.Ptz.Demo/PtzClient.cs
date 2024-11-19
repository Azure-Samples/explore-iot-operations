using System;
using Azure.Iot.Operations.Protocol;
using static PTZ.dtmi_onvif_ptz__1.Ptz;

namespace Aio.Onvif.Connector.Ptz.Demo;

public class PtzClient : Client
{
    public PtzClient(IMqttPubSubClient mqttClient) : base(mqttClient)
    {
    }
}
