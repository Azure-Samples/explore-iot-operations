using System;
using Azure.Iot.Operations.Protocol;
using static MediaClient.Media.Media;

namespace Aio.Onvif.Connector.Ptz.Demo;

public class OnvifMediaClient : Client
{
    public OnvifMediaClient(ApplicationContext applicationContext, IMqttPubSubClient mqttClient) : base(applicationContext, mqttClient)
    {
    }
}
