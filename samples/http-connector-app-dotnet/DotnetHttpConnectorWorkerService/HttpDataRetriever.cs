// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace DotnetHttpConnectorWorkerService
{
    internal class HttpDataRetriever
    {
        private readonly HttpClient _httpClient;
        private readonly string _httpPath;
        private readonly string _httpServerUsername;
        private readonly byte[] _httpServerPassword;
        private static readonly TimeSpan _defaultOperationTimeout = TimeSpan.FromSeconds(100);
        private bool _disposed = false;
        public HttpDataRetriever(string httpServerAddress, string httpPath, string httpServerUsername, byte[] httpServerPassword)
        {
            _httpClient = new HttpClient()
            {
                BaseAddress = new Uri(httpServerAddress),
                Timeout = _defaultOperationTimeout
            };

            _httpPath = httpPath;
            _httpServerUsername = httpServerUsername;
            _httpServerPassword = httpServerPassword;
        }

        private void Authenticate()
        {
            var byteArray = Encoding.ASCII.GetBytes($"{_httpServerUsername}:{Encoding.UTF8.GetString(_httpServerPassword)}");
            _httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(byteArray));
        }

        /*
        // The output will look something like this:
        country: uk
        viscosity: 0.51
        sweetness: 0.81
        particle_size: 0.71

        country: uk
        viscosity: 0.52
        sweetness: 0.82
        particle_size: 0.72
        */
        public async Task<string> RetrieveDataAsync()
        {
            // Implement HTTP data retrieval logic
            Authenticate();
            var response = await _httpClient.GetAsync(_httpPath);
            if (response.IsSuccessStatusCode)
            {
                string responseBody = await response.Content.ReadAsStringAsync();

                List<string> formattedRecords = new List<string>();

                using (JsonDocument document = JsonDocument.Parse(responseBody))
                {
                    JsonElement root = document.RootElement;

                    foreach (JsonElement record in root.EnumerateArray())
                    {
                        string formattedRecord = FormatRecord(record);
                        formattedRecords.Add(formattedRecord);
                    }
                }

                // Join all formatted records with double newlines
                return string.Join("\n\n", formattedRecords);
            }
            else
            {
                throw new HttpRequestException($"Request to {_httpClient.BaseAddress} failed with status code {response.StatusCode}");
            }
        }

        private static string FormatRecord(JsonElement record)
        {
            return string.Join("\n",
                record.EnumerateObject()
                    .Take(4)  // Limit to 4 properties as per requirement
                    .Select(prop => $"{prop.Name}: {FormatValue(prop.Value)}"));
        }

        private static string FormatValue(JsonElement value)
        {
            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString() ?? string.Empty, // Provide a default value
                JsonValueKind.Number => value.GetDouble().ToString(),
                _ => value.ToString()
            };
        }

        public void Dispose()
        {
            _httpClient?.Dispose();
            GC.SuppressFinalize(this);
        }
    }
}
