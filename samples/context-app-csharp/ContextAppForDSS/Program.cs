using Akri.Mqtt.Connection;
using Akri.Mqtt.Session;
using ContextualDataIngestor;
using Akri.Mq.StateStore;
using Akri.Mqtt;
using Akri.Mqtt.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.DependencyInjection;

namespace ContextualDataIngestor
{
    class Program
    {
        private static ILogger<Program>? _logger;

        static async Task Main(string[] args)
        {
            var serviceProvider = new ServiceCollection()
            .AddLogging(configure => configure.AddConsole())
            .BuildServiceProvider();

            var loggerFactory = serviceProvider.GetRequiredService<ILoggerFactory>();
            _logger = loggerFactory.CreateLogger<Program>();

            IDataRetriever dataRetriever = CreateDataRetriever();

            // MQTT Communication
            var mqttClient = await SetupMqttClient();
            StateStoreClient stateStoreClient = new(mqttClient);

            await retrieveAndStore(dataRetriever, stateStoreClient);
        }

        private static IDataRetriever CreateDataRetriever()
        {
            string authType = Environment.GetEnvironmentVariable("AUTH_TYPE") ?? throw new InvalidOperationException("AUTH_TYPE environment variable is not set");
            IAuthenticator authenticator = authType switch
            {
                "basic" => new BasicAuthenticator(
                    Environment.GetEnvironmentVariable("USERNAME") ?? throw new InvalidOperationException("USERNAME environment variable is not set"),
                    Environment.GetEnvironmentVariable("PASSWORD") ?? throw new InvalidOperationException("PASSWORD environment variable is not set")),
                _ => throw new InvalidOperationException("Unsupported authentication type")
            };

            string connectionStringOrBaseUrl = "http://my-backend-api-s.default.svc.cluster.local";
            string endpointTypeString = Environment.GetEnvironmentVariable("ENDPOINT_TYPE") ?? throw new InvalidOperationException("ENDPOINT_TYPE environment variable is not set");

            EndpointType endpointType = Enum.TryParse<EndpointType>(Environment.GetEnvironmentVariable("ENDPOINT_TYPE"),
            true,
            out var parsedType)
                ? parsedType
                : throw new ArgumentException("Invalid or missing ENDPOINT_TYPE environment variable");
            IDataRetriever dataRetriever = DataRetrieverFactory.CreateDataRetriever(endpointType, connectionStringOrBaseUrl, authenticator);
            return dataRetriever;
        }

        private static async Task retrieveAndStore(IDataRetriever dataRetriever, StateStoreClient stateStoreClient)
        {
            string connectionStringOrBaseUrl = "http://my-backend-api-s.default.svc.cluster.local";

            var retrievalRequest = new RetrievalConfig
            {
                ConnectionStringOrBaseUrl = connectionStringOrBaseUrl,
                Endpoint = "contexts/quality",
                RequestBody = null,
                DataFormat = null,
                QueryParams = null,
            };

            // Read interval from environment variable, default to 5 seconds if not set
            int intervalSeconds = int.TryParse(Environment.GetEnvironmentVariable("REQUEST_INTERVAL_SECONDS"), out int interval) ? interval : 5;
            string stateStoreKey = Environment.GetEnvironmentVariable("DSS_KEY") ?? throw new InvalidOperationException("DSS KEY environment variable is not set");

            try
            {
                while (true)
                {
                    try
                    {
                        string stateStoreValue = await dataRetriever.RetrieveDataAsync(retrievalRequest);
                        _logger.LogInformation("Store data in Distributed State Store");
                        await StoreData(stateStoreClient, stateStoreKey, stateStoreValue);
                    }
                    catch (Exception e)
                    {
                        _logger.LogError("Error retrieving or storing data: " + e.Message);
                    }

                    await Task.Delay(TimeSpan.FromSeconds(intervalSeconds));

                    _logger.LogInformation("Processing complete.");
                }
            }

            finally
            {
                await stateStoreClient.DisposeAsync(true);
            }
        }

        private static async Task<MqttSessionClient> SetupMqttClient()
        {
            var mqttClient = new MqttSessionClient();

            string host = Environment.GetEnvironmentVariable("MQTT_HOST") ?? "localhost";
            MqttConnectionSettings connectionSettings = new(host) { TcpPort = 1883, ClientId = "someClientId", UseTls = false };
            MqttClientConnectResult result = await mqttClient.ConnectAsync(connectionSettings);

            if (result.ResultCode != MqttClientConnectResultCode.Success)
            {
                throw new Exception($"Failed to connect to MQTT broker. Code: {result.ResultCode} Reason: {result.ReasonString}");
            }
            return mqttClient;
        }

        private static async Task StoreData(StateStoreClient stateStoreClient, string stateStoreKey, string stateStoreValue)
        {
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

            // Get and Delete just for testing purposes
            StateStoreGetResponse getResponse = await stateStoreClient.GetAsync(stateStoreKey);

            if (getResponse.Value != null)
            {
                _logger.LogInformation($"Current value of key {stateStoreKey} in the state store is {getResponse.Value.GetString()}");
            }
            else
            {
                _logger.LogError($"The key {stateStoreKey} is not currently in the state store");
            }

            StateStoreDeleteResponse deleteResponse = await stateStoreClient.DeleteAsync(stateStoreKey);

            if (deleteResponse.DeletedItemsCount == 1)
            {
                _logger.LogInformation($"Successfully deleted key {stateStoreKey} from the state store");
            }
            else
            {
                _logger.LogError($"Failed to delete key {stateStoreKey} from the state store");
            }
        }
    }
}