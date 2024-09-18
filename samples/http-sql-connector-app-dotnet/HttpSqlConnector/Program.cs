// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Microsoft.Extensions.Logging;
using ContextAppForDSS;

namespace ContextualDataIngestor
{
    class Program
    {
        static async Task Main(string[] args)
        {
            using ILoggerFactory factory = LoggerFactory.Create(builder => builder.AddConsole());
            ILogger logger = factory.CreateLogger("Program");
            DataSourceType dataSourceType = Enum.TryParse<DataSourceType>(Environment.GetEnvironmentVariable("ENDPOINT_TYPE"),
               true,
               out var parsedType)
                   ? parsedType
                   : throw new ArgumentException("Invalid or missing ENDPOINT_TYPE environment variable");

            Dictionary<string, string> parameters = CreateParametersFromEnvironmentVariables();
            using IDataRetriever dataRetriever = DataRetrieverFactory.CreateDataRetriever(dataSourceType, parameters);

            ContextualDataOperation operation = new ContextualDataOperation(dataRetriever, parameters, logger);
            await operation.PopulateContextualDataAsync();
        }

        public static Dictionary<string, string> CreateParametersFromEnvironmentVariables()
        {
            var parameters = new Dictionary<string, string>
            {
                { "HttpBaseURL", Environment.GetEnvironmentVariable("HTTP_BASE_URL") ?? string.Empty },
                { "HttpPath", Environment.GetEnvironmentVariable("HTTP_PATH") ?? string.Empty },
                { "AuthType", Environment.GetEnvironmentVariable("AUTH_TYPE") ?? string.Empty },
                { "HttpUsername", Environment.GetEnvironmentVariable("HTTP_USERNAME") ?? string.Empty },
                { "HttpPassword", Environment.GetEnvironmentVariable("HTTP_PASSWORD") ?? string.Empty },
                { "IntervalSecs", Environment.GetEnvironmentVariable("REQUEST_INTERVAL_SECONDS") ?? string.Empty },
                { "DssKey", Environment.GetEnvironmentVariable("DSS_KEY") ?? string.Empty },
                { "MqttHost", Environment.GetEnvironmentVariable("MQTT_HOST") ?? string.Empty },
                { "MqttClientId", Environment.GetEnvironmentVariable("MQTT_CLIENT_ID") ?? "someClientId"},
                { "SqlServerName",  Environment.GetEnvironmentVariable("SQL_SERVER_NAME") ?? string.Empty },
                { "SqlDatabaseName",  Environment.GetEnvironmentVariable("SQL_DB_NAME") ?? string.Empty },
                { "SqlTableName",  Environment.GetEnvironmentVariable("SQL_TABLE_NAME") ?? string.Empty },
                { "SqlUsername",  Environment.GetEnvironmentVariable("SQL_USERNAME") ?? "sa" },
                { "SqlPassword",  Environment.GetEnvironmentVariable("SQL_PASSWORD") ?? string.Empty },
                { "UseTls", Environment.GetEnvironmentVariable("USE_TLS") ?? "false"},
                { "SatTokenPath", Environment.GetEnvironmentVariable("SAT_TOKEN_PATH") ?? string.Empty},
                { "CaFilePath", Environment.GetEnvironmentVariable("CA_FILE_PATH") ?? string.Empty},
                { "ClientCertFilePath", Environment.GetEnvironmentVariable("CLIENT_CERT_FILE") ?? string.Empty},
                { "ClientCertKeyFilePath", Environment.GetEnvironmentVariable("CLIENT_KEY_FILE") ?? string.Empty},
                { "ClientKeyPassword", Environment.GetEnvironmentVariable("CLIENT_KEY_PASSWORD") ?? string.Empty},
            };

            return parameters;
        }
    }
}