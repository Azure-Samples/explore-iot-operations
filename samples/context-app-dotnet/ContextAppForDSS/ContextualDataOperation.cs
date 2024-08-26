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
            var mqttClient = new MqttSessionClient();

            string host = _parameters["MqttHost"] ?? throw new ArgumentException("Mqtt host name is not set.");
            string clientId = _parameters["MqttClientId"];
            int tcpPort = int.Parse(_parameters["MqttPort"] ?? "1883");
            MqttConnectionSettings connectionSettings = new(host) { TcpPort = tcpPort, ClientId = clientId, UseTls = false };

            bool useTls = bool.TryParse(Environment.GetEnvironmentVariable("USE_TLS"), out bool parsedTls) ? parsedTls : false;

            if (useTls)
            {
                _logger.LogInformation("Using TLS");
                tcpPort = int.Parse(_parameters["MqttPort"] ?? "8883");
                string caFilePath = _parameters["CaFilePath"] ?? throw new ArgumentException("Certificate authority file path is not set");

                bool hasSatToken = !string.IsNullOrEmpty(_parameters["SatTokenPath"]) && File.Exists(_parameters["SatTokenPath"]);
                bool hasClientPublicCert = !string.IsNullOrEmpty(_parameters["ClientCertFilePath"]) && File.Exists(_parameters["ClientCertFilePath"]);
                bool hasClientPrivateKey = !string.IsNullOrEmpty(_parameters["ClientCertKeyFilePath"]) && File.Exists(_parameters["ClientCertKeyFilePath"]);
                bool hasClientKeyPassword = !string.IsNullOrEmpty(_parameters["ClientKeyPassword"]);

                if (hasSatToken)
                {
                    _logger.LogInformation("SAT Token path is set and will be used for authentication.");
                    string tokenPath = _parameters["SatTokenPath"];
                    connectionSettings = new(host) { TcpPort = 8883, ClientId = clientId, UseTls = true, CaFile = caFilePath, SatAuthFile = tokenPath };
                }
                else if (hasClientPublicCert && hasClientPrivateKey)
                {
                    _logger.LogInformation("Client certificate and key are set and will be used for authentication.");
                    if (!hasClientKeyPassword)
                    {
                        _logger.LogWarning("Client key password is not set. Ensure the key is not password-protected.");
                    }
                    string clientCertFile = _parameters["ClientCertFilePath"];
                    string clientKeyFile = _parameters["ClientCertKeyFilePath"];
                    string keyPassword = _parameters["ClientKeyPassword"] ?? string.Empty;

                    connectionSettings = new(host) { TcpPort = tcpPort, ClientId = clientId, UseTls = true, CaFile = caFilePath, CertFile = clientCertFile, KeyFile = clientKeyFile, KeyFilePassword = keyPassword };
                }
                else
                {
                    _logger.LogError("Neither SAT Token path nor Client Certificate with Key are properly configured.");
                    throw new InvalidOperationException("TLS is enabled but no authentication method is set. Please ensure either SAT token or both Client Cert and Client Key files are set.");
                }
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
