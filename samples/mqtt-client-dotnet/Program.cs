// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using MQTTnet.Client;
using MQTTnet.Formatter;
using MQTTnet;

namespace SampleDotnetMqtt
{
    class Program
    {
        const string token_path = "/var/run/secrets/tokens/mqtt-client-token";
        const string broker = "aio-mq-dmqtt-frontend";

        public static int Main() => MainAsync().Result;

        static async Task<int> MainAsync()
        {
            Console.WriteLine("Started MQTT client.");

            // Read SAT Token
            var satToken = File.ReadAllText(token_path);
            Console.WriteLine("SAT token read.");
            
            // Create a new MQTT client.
            var mqttFactory = new MqttFactory();
            using (var mqttClient = mqttFactory.CreateMqttClient())
            {
                // Create TCP based options using the builder amd connect to broker
                var mqttClientOptions = new MqttClientOptionsBuilder()
                    .WithTcpServer(broker, 1883)
                    .WithProtocolVersion(MqttProtocolVersion.V500)
                    .WithClientId("sampleid")
                    .WithCredentials("$sat", satToken)
                    .Build();

                // Connect to MQTT client
                var response = await mqttClient.ConnectAsync(mqttClientOptions, CancellationToken.None);

                Console.WriteLine("The MQTT client is connected.");
                
                // To compose application message and publish
                var counter = 1;
                while (true) 
                {
                    var applicationMessage = new MqttApplicationMessageBuilder()
                        .WithTopic("sampletopic")
                        .WithPayload("samplepayload" + counter++)
                        .Build();

                    await mqttClient.PublishAsync(applicationMessage, CancellationToken.None);
                    Console.WriteLine($"The MQTT client published the message: {applicationMessage.ConvertPayloadToString()}");

                    Thread.Sleep(2000);
                }
            }
        }
    }
}