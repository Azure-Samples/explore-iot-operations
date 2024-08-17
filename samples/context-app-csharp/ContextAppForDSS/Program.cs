using Akri.Mqtt.Connection;
using Akri.Mqtt.Session;
using Akri.Mq.StateStore;
using Akri.Mqtt.Models;
using Microsoft.Extensions.Logging;
using ContextAppForDSS;

namespace ContextualDataIngestor
{
    class Program
    {
        private static ILogger<Program>? _logger;

        static async Task Main(string[] args)
        {
            using ILoggerFactory factory = LoggerFactory.Create(builder => builder.AddConsole());
            ILogger logger = factory.CreateLogger("Program");
            await PopulateContextualDataAsync();
        }

        private static IDataRetriever CreateDataRetriever()
        {
            string connectionStringOrBaseUrl = Environment.GetEnvironmentVariable("DS_ENDPOINT") ?? throw new InvalidOperationException("DS_ENDPOINT environment variable is not set");
            string endpointTypeString = Environment.GetEnvironmentVariable("ENDPOINT_TYPE") ?? throw new InvalidOperationException("ENDPOINT_TYPE environment variable is not set");

            EndpointType endpointType = Enum.TryParse<EndpointType>(Environment.GetEnvironmentVariable("ENDPOINT_TYPE"),
            true,
            out var parsedType)
                ? parsedType
                : throw new ArgumentException("Invalid or missing ENDPOINT_TYPE environment variable");

            string authType = Environment.GetEnvironmentVariable("AUTH_TYPE") ?? throw new InvalidOperationException("AUTH_TYPE environment variable is not set");
            IDataRetriever dataRetriever = DataRetrieverFactory.CreateDataRetriever(endpointType, connectionStringOrBaseUrl, CreateAuth(authType));

            return dataRetriever;
        }

        private static IAuthConfig CreateAuth(string authType)
        {
            switch (authType.ToLower())
            {
                case "httpbasic":
                    return new HttpBasicAuth
                    {
                        Username = Environment.GetEnvironmentVariable("USERNAME") ?? throw new InvalidOperationException("USERNAME environment variable is not set"),
                        Password = Environment.GetEnvironmentVariable("PASSWORD") ?? throw new InvalidOperationException("PASSWORD environment variable is not set")
                    };
                case "sqlbasic":
                    return new SqlBasicAuth();
                default:
                    throw new ArgumentException("Invalid auth type");
            }
        }

        private static async Task PopulateContextualDataAsync()
        {
            IDataRetriever dataRetriever = CreateDataRetriever();

            // MQTT Communication
            var mqttClient = await SetupMqttClient();
            IStateStoreClient stateStoreClient = new StateStoreClient(mqttClient);

            // Read interval from environment variable, default to 5 seconds if not set
            int intervalSeconds = int.TryParse(Environment.GetEnvironmentVariable("REQUEST_INTERVAL_SECONDS"), out int interval) ? interval : 5;
            string stateStoreKey = Environment.GetEnvironmentVariable("DSS_KEY") ?? throw new InvalidOperationException("DSS KEY environment variable is not set");
            
            try
            {
                ContextualDataOperation operation = new ContextualDataOperation(stateStoreClient, dataRetriever, stateStoreKey, intervalSeconds);
                await operation.PopulateContextualDataLoopAsync();
            }
            finally
            {
                await stateStoreClient.DisposeAsync(true);
                dataRetriever.Dispose();
            }
        }

        private static async Task<MqttSessionClient> SetupMqttClient()
        {
            var mqttClient = new MqttSessionClient();

            string host = Environment.GetEnvironmentVariable("MQTT_HOST") ?? "localhost";
            string clientId = Environment.GetEnvironmentVariable("MQTT_CLIENT_ID") ?? "someClientId";
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