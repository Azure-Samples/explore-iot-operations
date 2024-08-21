﻿// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading.Tasks;

namespace ContextualDataIngestor
{
    internal class DataRetrieverFactory
    {
        public static IDataRetriever CreateDataRetriever(DataSourceType endpointType, Dictionary<string, string> parameters)
        {
            switch (endpointType)
            {
                case DataSourceType.Sql:
                    IAuthStrategy sqlAuthStrategy = CreateAuthStrategy(parameters);
                    var retrievalReq = new SqlRetrievalConfig
                    {
                        ServerName = parameters["SqlServerName"] ?? throw new ArgumentException("Server name variable is not set for SQL."),
                        DatabaseName = parameters["SqlDatabaseName"] ?? throw new ArgumentException("Database name variable is not set for SQL."),
                        TableName = parameters["SqlTableName"] ?? throw new ArgumentException("Table variable is not set for SQL.")
                    };
                    Console.WriteLine("Inside SQL Block. Creating Retriever");
                    return new SqlDataRetriever(
                        retrievalReq,
                        sqlAuthStrategy
                    );
                case DataSourceType.Http:
                    IAuthStrategy httpAuthStrategy = CreateAuthStrategy(parameters);
                    var retrievalRequest = new HttpRetrievalConfig
                    {
                        ConnectionStringOrBaseUrl = parameters["HttpBaseURL"] ?? throw new ArgumentException("Base url variable is not set for HTTP."),
                        Endpoint = parameters["HttpPath"] ?? throw new ArgumentException("full path variable is not set for HTTP."),
                        RequestBody = null,
                        DataFormat = null,
                        QueryParams = null,
                    };
                    return new HttpDataRetriever(
                        retrievalRequest,
                        httpAuthStrategy
                    );
                default:
                    throw new ArgumentException("Invalid endpoint type", nameof(endpointType));
            }
        }

        private static IAuthStrategy CreateAuthStrategy(Dictionary<string, string> parameters)
        {
            AuthType authType = Enum.TryParse<AuthType>(parameters["AuthType"],
            true,
            out var parsedType)
                ? parsedType
                : throw new ArgumentException("Invalid or missing ENDPOINT_TYPE environment variable");

            switch (authType)
            {
                case AuthType.Httpbasic:
                    return new HttpBasicAuth
                    {
                        Username = parameters["HttpUsername"] ?? throw new ArgumentException("username variable is not set for basic auth strategy in HTTP"),
                        Password = parameters["HttpPassword"] ?? throw new ArgumentException("password variable is not set for basic auth strategy in HTTP")
                    };
                case AuthType.Sqlbasic:
                    return new SqlBasicAuth
                    {
                        Username = parameters["SqlUsername"] ?? throw new ArgumentException("username variable is not set for basic auth strategy in SQL"),
                        Password = parameters["SqlPassword"] ?? throw new ArgumentException("password variable is not set for basic auth strategy in SQL")
                    };
                default:
                    throw new ArgumentException("Invalid auth type");
            }
        }
    }
}
