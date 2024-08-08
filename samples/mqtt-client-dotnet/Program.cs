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
        static string hostname = "aio-mq-dmqtt-frontend";
        static int tcp_port = 8883;
        static bool use_tls = true;
        static string ca_file = "/var/run/certs/aio-mq-ca-cert/ca.crt";
        static string sat_auth_file = "/var/run/secrets/tokens/mqtt-client-token";

        public static int Main() => MainAsync().Result;

        static void LoadEnv()
        {
            Console.WriteLine("Reading environment variables.");
            var _hostname = Environment.GetEnvironmentVariable("hostname");
            var _tcp_port = Environment.GetEnvironmentVariable("tcpPort");
            var _use_tls = Environment.GetEnvironmentVariable("useTls");
            var _ca_file = Environment.GetEnvironmentVariable("caFile");
            var _sat_auth_file = Environment.GetEnvironmentVariable("satAuthFile");

            if (_hostname != null)
            {
                hostname = _hostname;
            }

            if (_tcp_port != null)
            {
                Int32.TryParse(_tcp_port, out tcp_port);
            }

            if (_use_tls != null)
            {
                use_tls = (_use_tls.ToLower() == "true");
            }

            if (_ca_file != null)
            {
                ca_file = _ca_file;
            }

            if (_sat_auth_file != null)
            {
                sat_auth_file = _sat_auth_file;
            }                        
        }

        static async Task<int> MainAsync()
        {
            Console.WriteLine("Started MQTT client.");

            LoadEnv();

            // Read cert
            var ca_certs = File.ReadAllText(ca_file);
            Console.WriteLine("CA cert read.");

            // Read SAT Token
            var satToken = File.ReadAllText(sat_auth_file);
            Console.WriteLine("SAT token read.");
            
            // Create a new MQTT client
            var mqttFactory = new MqttFactory();
            using (var mqttClient = mqttFactory.CreateMqttClient())
            {
                // Create TCP based options using the builder amd connect to broker
                var mqttClientOptions = new MqttClientOptionsBuilder()
                    .WithTcpServer(hostname, tcp_port)
                    .WithProtocolVersion(MqttProtocolVersion.V311)
                    .WithClientId("mqtt-client-dotnet")
                    .WithCredentials("K8S-SAT", satToken);

                if (use_tls)
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