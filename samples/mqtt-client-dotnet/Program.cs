// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using MQTTnet.Client;
using MQTTnet.Formatter;
using MQTTnet;
using System.Security.Authentication;
using System.Runtime.ConstrainedExecution;

namespace SampleDotnetMqtt
{
    class Program
    {
        const string token_path = "/var/run/secrets/tokens/mqtt-client-token";
        const string cert_path = "/certs/aio-mq-ca-cert/ca.pem";
        
        static string host_name = "aio-mq-dmqtt-frontend";
        static bool tls_enabled = true;
        static int port = 8883;

        public static int Main() => MainAsync().Result;

        static void LoadEnv()
        {
            Console.WriteLine("Reading environment variables.");
            var _host_name = Environment.GetEnvironmentVariable("IOT_MQ_HOST_NAME");
            var _port = Environment.GetEnvironmentVariable("IOT_MQ_PORT");
            var _tls_enabled = Environment.GetEnvironmentVariable("IOT_MQ_TLS_ENABLED");

            if (_host_name != null)
            {
                host_name = _host_name;
            }

            if (_port != null)
            {
                Int32.TryParse(_port, out port);
            }

            if (_tls_enabled != null)
            {
                tls_enabled = (_tls_enabled.ToLower() == "true");
            }
        }

        static async Task<int> MainAsync()
        {
            Console.WriteLine("Started MQTT client.");

            LoadEnv();

            // Read cert
            var ca_certs = File.ReadAllText(cert_path);
            Console.WriteLine("CA cert read.");

            // Read SAT Token
            var satToken = File.ReadAllText(token_path);
            Console.WriteLine("SAT token read.");
            
            // Create a new MQTT client.
            var mqttFactory = new MqttFactory();
            using (var mqttClient = mqttFactory.CreateMqttClient())
            {
                // Create TCP based options using the builder amd connect to broker
                var mqttClientOptions = new MqttClientOptionsBuilder()
                    .WithTcpServer(host_name, port)
                    .WithProtocolVersion(MqttProtocolVersion.V500)
                    .WithClientId("sampleid")
                    .WithCredentials("$sat", satToken);

                if (tls_enabled)
                {
                    mqttClientOptions.WithTlsOptions(
                        o =>
                        {
                            o.WithCertificateValidationHandler(_ => true);
                            o.WithSslProtocols(SslProtocols.Tls12);
                        }
                    );
                }

                // Connect to MQTT client
                var response = await mqttClient.ConnectAsync(mqttClientOptions.Build(), CancellationToken.None);

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