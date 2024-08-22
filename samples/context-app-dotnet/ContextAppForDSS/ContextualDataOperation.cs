// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Akri.Mq.StateStore;
using Akri.Mqtt.Connection;
using Akri.Mqtt.Session;
using ContextualDataIngestor;
using Microsoft.Extensions.Logging;
using System.Runtime.CompilerServices;
using Akri.Mqtt.Models;

namespace ContextAppForDSS
{
    internal class ContextualDataOperation : IDisposable
    {
        private IDataRetriever _dataRetriever;
        private ILogger _logger;
        private readonly Dictionary<string, string> _parameters;

        public ContextualDataOperation(IDataRetriever dataRetriever, Dictionary<string, string> parameters, ILogger logger)
        {
            _parameters = parameters;
            _dataRetriever = dataRetriever;
            _logger = logger;
        }

        public async Task PopulateContextualDataAsync()
        {

            // MQTT Communication
            await using MqttSessionClient mqttClient = await SetupMqttClientAsync();
            await using IStateStoreClient stateStoreClient = new StateStoreClient(mqttClient);

            // Read interval from environment variable, default to 5 seconds if not set
            int intervalSeconds = int.TryParse(_parameters["IntervalSecs"], out int interval) ? interval : 5;
            string stateStoreKey = _parameters["DssKey"] ?? throw new ArgumentException("Dss Key variable is not set for the store operation to happen.");

            _logger.LogInformation("Starting.");
            while (true)
            {
                try
                {
                    _logger.LogInformation("Retrieve data from at source.");
                    string stateStoreValue = await _dataRetriever.RetrieveDataAsync();
                    _logger.LogInformation("Store data in Distributed State Store");
                    StateStoreSetResponse setResponse =
                    await stateStoreClient.SetAsync(stateStoreKey, stateStoreValue);

                    if (setResponse.Success)
                    {
                        _logger.LogInformation($"Successfully set key {stateStoreKey} with value {stateStoreValue}");
                    }
                    else
                    {
                        _logger.LogError($"Failed to set key {stateStoreKey} with value {stateStoreValue}");
                    }
                }
                catch (Exception e)
                {
                    _logger.LogError(e, "Error retrieving or storing data.");
                }

                await Task.Delay(TimeSpan.FromSeconds(intervalSeconds));
            }
        }
        private async Task<MqttSessionClient> SetupMqttClientAsync()
        {
            _logger.LogInformation("Setting up MQTT client");
            var mqttClient = new MqttSessionClient();

            string host = _parameters["MqttHost"] ?? throw new ArgumentException("Mqtt host name is not set.");
            string clientId = _parameters["MqttClientId"];
            MqttConnectionSettings connectionSettings = new(host) { TcpPort = 1883, ClientId = clientId, UseTls = false };

            bool useTls = bool.TryParse(Environment.GetEnvironmentVariable("USE_TLS"), out bool parsedTls) ? parsedTls : false;

            if (useTls)
            {
                _logger.LogInformation("Using TLS");
                string tokenPath = _parameters["SatTokenPath"] ?? throw new InvalidOperationException("Service Account Token is not set");
                Console.WriteLine("read token to see contents");
                Console.WriteLine(File.ReadAllText(tokenPath).Trim());
                string caFilePath = _parameters["CaFilePath"] ?? throw new InvalidOperationException("Certificate authority file path is not set");
                Console.WriteLine("read ca file to see contents");
                Console.WriteLine(File.ReadAllText(caFilePath).Trim());
                connectionSettings = new(host) { TcpPort = 8883, ClientId = clientId, UseTls = true, SatAuthFile = tokenPath, CaFile = caFilePath };
            }

            MqttClientConnectResult result = await mqttClient.ConnectAsync(connectionSettings);

            if (result.ResultCode != MqttClientConnectResultCode.Success)
            {
                throw new Exception($"Failed to connect to MQTT broker. Code: {result.ResultCode} Reason: {result.ReasonString}");
            }
            return mqttClient;
        }

        public void Dispose()
        {
            _dataRetriever.Dispose();
        }
    }
}
