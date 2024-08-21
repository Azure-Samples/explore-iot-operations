// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using ContextualDataIngestor;
using System;
using System.Data.SqlClient;
using System.Text;
using System.Threading.Tasks;
using static System.Runtime.InteropServices.JavaScript.JSType;
using Microsoft.Extensions.Logging;

namespace ContextualDataIngestor
{
    internal class SqlDataRetriever : IDataRetriever
    {
        private string _connectionString;
        private string _query;
        private readonly IAuthStrategy _authConfig;

        public SqlDataRetriever(SqlRetrievalConfig retrievalConfig, IAuthStrategy authConfig)
        {
            _connectionString = $"Server={retrievalConfig.ServerName};Database={retrievalConfig.DatabaseName};";
            _query = $"SELECT * FROM {retrievalConfig.TableName}";
            _authConfig = authConfig;
        }

        private void Authenticate()
        {
            if (_authConfig.GetType() == typeof(SqlBasicAuth))
            {
                SqlBasicAuth basicAuth = (SqlBasicAuth)_authConfig;
                _connectionString = _connectionString + $"User Id={basicAuth.Username};Password={basicAuth.Password};";
            }
        }

        public async Task<string> RetrieveDataAsync()
        {
            Authenticate();
            StringBuilder result = new StringBuilder();

            using (SqlConnection connection = new SqlConnection(_connectionString))
            {
                try
                {
                    await connection.OpenAsync();
                    using (SqlCommand command = new SqlCommand(_query, connection))
                    {
                        using (SqlDataReader reader = await command.ExecuteReaderAsync())
                        {
                            if (reader.HasRows)
                            {
                                while (await reader.ReadAsync())
                                {
                                    string formattedRow = $"{{ \"country\" : \"{reader["Country"]}\" , \"viscosity\" : {reader["Viscosity"]}, \"sweetness\" : {reader["Sweetness"]}, \"particle_size\" : {reader["ParticleSize"]}, \"overall\" : {reader["Overall"]} }}";
                                    result.AppendLine(formattedRow);
                                }
                            }
                            else
                            {
                                result.AppendLine("No data found.");
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    throw;
                }
            }

            return result.ToString();
        }



        public void Dispose()
        {
            // No resources to dispose as of now
        }
    }
}