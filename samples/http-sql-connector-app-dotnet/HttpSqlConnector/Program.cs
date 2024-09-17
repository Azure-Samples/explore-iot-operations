// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using Microsoft.Extensions.Logging;
using ContextAppForDSS;
using System.Text.Json;

namespace ContextualDataIngestor
{
    class Program
    {
        static async Task Main(string[] args)
        {
            using ILoggerFactory factory = LoggerFactory.Create(builder => builder.AddConsole());
            ILogger logger = factory.CreateLogger("Program");

            string? configmapMountPath = Environment.GetEnvironmentVariable("CONFIGMAP_MOUNT_PATH");
            string? secretMountPath = Environment.GetEnvironmentVariable("SECRET_MOUNT_PATH");
            string? satMountPath = Environment.GetEnvironmentVariable("SAT_MOUNT_PATH");
            string? tlsCertMountPath = Environment.GetEnvironmentVariable("TLS_CERT_MOUNT_PATH");

            DataSourceType dataSourceType;
            Dictionary<string, string> parameters;

            if (string.IsNullOrWhiteSpace(configmapMountPath) || string.IsNullOrWhiteSpace(secretMountPath))
            {
                Console.WriteLine("Volume mount path not provided, so reading the configuration from environment variables");

                dataSourceType = Enum.TryParse<DataSourceType>(Environment.GetEnvironmentVariable("ENDPOINT_TYPE"),
                    true,
                    out var parsedType)
                        ? parsedType
                        : throw new ArgumentException("Invalid or missing ENDPOINT_TYPE environment variable");

                parameters = CreateParametersFromEnvironmentVariables();
            }
            else
            {
                Console.WriteLine($"Reading the configuration from mounted volumes at:\n\t{configmapMountPath}, \n\t{secretMountPath}, \n\t{satMountPath}, \n\t{tlsCertMountPath}");

                if (!Directory.Exists(configmapMountPath))
                {
                    Console.WriteLine($"ConfigMap mount path does not exist: {configmapMountPath}");
                    return;
                }

                if (!Directory.Exists(secretMountPath))
                {
                    Console.WriteLine($"Secret mount path does not exist: {secretMountPath}");
                    return;
                }

                string? appAdditionalConfigurationString = GetMountedConfigurationValue($"{configmapMountPath}/APP_ADDITIONAL_CONFIGURATION");
                if (string.IsNullOrEmpty(appAdditionalConfigurationString))
                {
                    Console.WriteLine("Missing APP_ADDITIONAL_CONFIGURATION which specifies the data source type");
                    return;
                }

                AppAdditionalConfiguration appAdditionalConfiguration = JsonSerializer.Deserialize<AppAdditionalConfiguration>(appAdditionalConfigurationString) ?? throw new ArgumentException("Invalid APP_ADDITIONAL_CONFIGURATION");
                dataSourceType = appAdditionalConfiguration.DataSourceType;      // ENDPOINT_TYPE    // AEP => APP_ADDITIONAL_CONFIGURATION

                if (dataSourceType == DataSourceType.Unspecified)
                {
                    throw new ArgumentException("Invalid data source type supplied in APP_ADDITIONAL_CONFIGURATION");
                }

                parameters = CreateParametersFromMountedVolumeVariables(configmapMountPath, secretMountPath, satMountPath, tlsCertMountPath, appAdditionalConfiguration);
            }

            using IDataRetriever dataRetriever = DataRetrieverFactory.CreateDataRetriever(dataSourceType, parameters);

            ContextualDataOperation operation = new ContextualDataOperation(dataRetriever, parameters, logger);
            await operation.PopulateContextualDataAsync();
        }

        static Dictionary<string, string> CreateParametersFromEnvironmentVariables()
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
                { "MqttPort", Environment.GetEnvironmentVariable("MQTT_PORT") ?? string.Empty },
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

        static Dictionary<string, string> CreateParametersFromMountedVolumeVariables(string configmapMountPath,
            string secretMountPath,
            string? satMountPath,
            string? tlsCertMountPath,
            AppAdditionalConfiguration appAdditionalConfiguration)
        {
            var parameters = new Dictionary<string, string>
            {
                { "HttpBaseURL", GetMountedConfigurationValue($"{configmapMountPath}/APP_TARGET_ADDRESS") ?? string.Empty },        // HTTP_BASE_URL                // AEP
                { "HttpPath", appAdditionalConfiguration.HttpPath ?? string.Empty },                                                // HTTP_PATH                    // AEP => APP_ADDITIONAL_CONFIGURATION
                { "AuthType", GetMountedConfigurationValue($"{configmapMountPath}/APP_AUTHENTICATION_METHOD") ?? string.Empty },    // AUTH_TYPE                    // AEP
                { "Username", GetMountedConfigurationValue($"{secretMountPath}/APP_USERNAME_SECRET_NAME") ?? string.Empty },        // HTTP_USERNAME                // AEP
                { "Password", GetMountedConfigurationValue($"{secretMountPath}/APP_PASSWORD_SECRET_NAME") ?? string.Empty },        // HTTP_PASSWORD                // AEP
                { "IntervalSecs", appAdditionalConfiguration.RequestIntervalInSeconds.ToString() ?? string.Empty },                 // REQUEST_INTERVAL_SECONDS     // AEP => APP_ADDITIONAL_CONFIGURATION
                { "DssKey", appAdditionalConfiguration.DssKey ?? string.Empty },                                                    // DSS_KEY                      // AEP => APP_ADDITIONAL_CONFIGURATION      // This is the key for DSS state store object => would probably have more than one value for the "key"?
                { "MqttHost", GetMountedConfigurationValue($"{configmapMountPath}/MQ_TARGET_ADDRESS") ?? string.Empty },            // MQTT_HOST                    // CONNECTOR CONFIG
                { "MqttClientId", appAdditionalConfiguration.MqttClientId ?? "someClientId"},                                       // MQTT_CLIENT_ID               // AEP => APP_ADDITIONAL_CONFIGURATION      // Should this be in CONNECTOR CONFIG?
                { "MqttPort", (GetMountedConfigurationValue($"{configmapMountPath}/MQ_USE_TLS") ?? string.Empty).Equals("true", StringComparison.OrdinalIgnoreCase) ? "8883" : "1883" }, // MQTT_PORT   // CONNECTOR CONFIG     // NEW => infer from mqTls
                { "SqlServerName",  GetMountedConfigurationValue($"{configmapMountPath}/APP_TARGET_ADDRESS") ?? "sa" },             // SQL_SERVER_NAME              // AEP
                { "SqlDatabaseName",  appAdditionalConfiguration.SqlDatabaseName ?? string.Empty },                                 // SQL_DB_NAME                  // AEP => APP_ADDITIONAL_CONFIGURATION
                { "SqlTableName",  appAdditionalConfiguration.SqlTableName ?? string.Empty },                                       // SQL_TABLE_NAME               // AEP => APP_ADDITIONAL_CONFIGURATION
                { "UseTls", GetMountedConfigurationValue($"{configmapMountPath}/MQ_USE_TLS") ?? "false"},                           // USE_TLS                      // CONNECTOR CONFIG                         // NEW
                { "ClientCertFilePath", GetMountedConfigurationValue($"{secretMountPath}/CLIENT_CERT_FILE") ?? string.Empty},       // CLIENT_CERT_FILE             // CONNECTOR CONFIG                         // mqAuthentication?
                { "ClientCertKeyFilePath", GetMountedConfigurationValue($"{secretMountPath}/CLIENT_KEY_FILE") ?? string.Empty},     // CLIENT_KEY_FILE              // CONNECTOR CONFIG                         // mqAuthentication?
                { "ClientKeyPassword", GetMountedConfigurationValue($"{secretMountPath}/CLIENT_KEY_PASSWORD") ?? string.Empty}      // CLIENT_KEY_PASSWORD          // CONNECTOR CONFIG                         // mqAuthentication?
            };

            if (!string.IsNullOrEmpty(satMountPath))
            {
                parameters["SatTokenPath"] = $"{satMountPath}/SAT" ?? string.Empty;                                                 // SAT_TOKEN_PATH               // CONNECTOR CONFIG                         // indirectly from mqAudience
            }
            else
            {
                parameters["SatTokenPath"] = string.Empty;
            }

            if (!string.IsNullOrEmpty(tlsCertMountPath))
            {
                parameters["CaFilePath"] = $"{tlsCertMountPath}/tls.crt" ?? string.Empty;                                            // CA_FILE_PATH                 // CONNECTOR CONFIG                         // NEW => mqTls
            }
            else
            {
                parameters["CaFilePath"] = string.Empty;
            }

            return parameters;
        }

        static string? GetMountedConfigurationValue(string path)
        {
            if (!File.Exists(path))
            {
                return null;
            }

            using (var reader = new StreamReader(path))
            {
                return reader.ReadToEnd();
            }
        }
    }
}