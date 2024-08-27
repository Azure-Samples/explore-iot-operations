// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Akri.Mq.StateStore;
using Akri.Mqtt.Connection;
using Akri.Mqtt.MqttNetAdapter.Session;
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

            string host = _parameters["MqttHost"] ?? throw new ArgumentException("Mqtt host name is not set.");
            string clientId = _parameters["MqttClientId"];

            MqttConnectionSettings connectionSettings = new(host)
            {
                TcpPort = string.IsNullOrEmpty(_parameters["MqttPort"]) ? 1883 : int.Parse(_parameters["MqttPort"]),
                ClientId = clientId,
                UseTls = false,
            };

            bool useTls = bool.TryParse(Environment.GetEnvironmentVariable("USE_TLS"), out bool parsedTls) ? parsedTls : false;
            if (useTls)
            {
                _logger.LogInformation("TLS is enabled. Certificate authority is needed. Port 8883 will be used unless a custom value has been set.");
                connectionSettings.TcpPort = string.IsNullOrEmpty(_parameters["MqttPort"]) ? 8883 : int.Parse(_parameters["MqttPort"]);
                connectionSettings.UseTls = true;
                connectionSettings.CaFile = _parameters["CaFilePath"] ?? throw new ArgumentException("TLS is set but certificate authority file path is not set");
            }
            else
            {
                _logger.LogInformation("TLS is disabled.");
            }

            // SAT can happen with or without TLS
            if (!string.IsNullOrEmpty(_parameters["SatTokenPath"]))
            {
                _logger.LogInformation("SAT Token path is set and will be used for authentication.");
                connectionSettings.SatAuthFile = _parameters["SatTokenPath"];
            }

            bool hasClientPublicCert = !string.IsNullOrEmpty(_parameters["ClientCertFilePath"]) && File.Exists(_parameters["ClientCertFilePath"]);
            bool hasClientPrivateKey = !string.IsNullOrEmpty(_parameters["ClientCertKeyFilePath"]) && File.Exists(_parameters["ClientCertKeyFilePath"]);
            bool hasClientKeyPassword = !string.IsNullOrEmpty(_parameters["ClientKeyPassword"]);

            if (hasClientPublicCert && hasClientPrivateKey)
            {
                if (!useTls)
                {
                    throw new InvalidOperationException("X509 authentication method is set but TLS is disabled.");
                }

                _logger.LogInformation("Client certificate and key are set and will be used for authentication.");
                if (!hasClientKeyPassword)
                {
                    _logger.LogWarning("Client key password is not set. Ensure the key is not password-protected.");
                }

                connectionSettings.CertFile = _parameters["ClientCertFilePath"];
                connectionSettings.KeyFile = _parameters["ClientCertKeyFilePath"];
                connectionSettings.KeyFilePassword = _parameters["ClientKeyPassword"] ?? string.Empty;
            }

            var mqttClient = new MqttSessionClient();
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
