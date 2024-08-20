using Akri.Mq.StateStore;
using Akri.Mqtt.Connection;
using Akri.Mqtt.Session;
using ContextualDataIngestor;
using Microsoft.Extensions.Logging;
using System.Runtime.CompilerServices;
using Akri.Mqtt.Models;

namespace ContextAppForDSS
{
    internal class ContextualDataOperation
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
            await using MqttSessionClient mqttClient = await SetupMqttClient();
            IStateStoreClient stateStoreClient = new StateStoreClient(mqttClient);

            // Read interval from environment variable, default to 5 seconds if not set
            int intervalSeconds = int.TryParse(_parameters["IntervalSecs"], out int interval) ? interval : 5;
            string stateStoreKey = _parameters["DssKey"] ?? throw new ArgumentException("Dss Key variable is not set for the store operation to happen.");

            try
            {
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
                        _logger.LogError("Error retrieving or storing data: " + e.Message);
                    }

                    await Task.Delay(TimeSpan.FromSeconds(intervalSeconds));
                }
            }
            finally
            {
                await stateStoreClient.DisposeAsync(true);
                _dataRetriever.Dispose();
            }
        }

        private async Task<MqttSessionClient> SetupMqttClient()
        {
            var mqttClient = new MqttSessionClient();

            string host = _parameters["MqttHost"] ?? throw new ArgumentException("Mqtt host name is not set.");
            string clientId = _parameters["MqttClientId"];
            MqttConnectionSettings connectionSettings = new(host) { TcpPort = 1883, ClientId = clientId, UseTls = false };
            MqttClientConnectResult result = await mqttClient.ConnectAsync(connectionSettings);

            if (result.ResultCode != MqttClientConnectResultCode.Success)
            {
                throw new Exception($"Failed to connect to MQTT broker. Code: {result.ResultCode} Reason: {result.ReasonString}");
            }
            return mqttClient;
        }
    }
}
