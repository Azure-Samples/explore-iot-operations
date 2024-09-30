// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Azure.Iot.Operations.Mqtt.Session;
using Azure.Iot.Operations.Protocol.Connection;
using Azure.Iot.Operations.Protocol.Models;
using System.Text.Json;

namespace DotnetHttpConnectorWorkerService
{
    public class Worker : BackgroundService
    {
        private readonly ILogger<Worker> _logger;

        public Worker(ILogger<Worker> logger)
        {
            _logger = logger;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                // ADR client stub
                string targetAddress = "";
                string authenticationMethod = "";
                string endpointProfileType = "";
                JsonDocument? additionalConfiguration = null;
                string? assetEndpointProfileUsername = "";
                byte[]? assetEndpointProfilePassword = new byte[0];
                string? assetEndpointProfileCertificate = "";

                HttpDataRetriever httpDataRetriever = new(targetAddress, "todo", assetEndpointProfileUsername, assetEndpointProfilePassword);

                MqttConnectionSettings mqttConnectionSettings = null;
                MqttSessionClient sessionClient = null;

                await sessionClient.ConnectAsync(mqttConnectionSettings);

                while (true)
                {
                    // Read data from the 3rd party asset
                    string httpData = await httpDataRetriever.RetrieveDataAsync();
                    
                    // Send that data to the Azure IoT Operations broker
                    await sessionClient.PublishAsync(new MqttApplicationMessage("todo"));

                    await Task.Delay(TimeSpan.FromSeconds(5));
                }
            }
        }
    }
}
