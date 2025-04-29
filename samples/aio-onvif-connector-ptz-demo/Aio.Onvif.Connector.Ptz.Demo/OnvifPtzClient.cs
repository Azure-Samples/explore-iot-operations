using System;
using Azure.Iot.Operations.Protocol;
using static PtzClient.Ptz.Ptz;


namespace Aio.Onvif.Connector.Ptz.Demo;

public class OnvifPtzClient : Client
{
    public OnvifPtzClient(ApplicationContext applicationContext, IMqttPubSubClient mqttClient) : base(applicationContext, mqttClient)
    {
    }
}
