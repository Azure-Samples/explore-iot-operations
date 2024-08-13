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
        private static readonly TimeSpan defaultOperationTimeout = TimeSpan.FromSeconds(100);

        public static IDataRetriever CreateDataRetriever(string endpointType, string connectionStringOrBaseUrl, IAuthenticator authenticator = null)
        {
            return endpointType.ToLower() switch
            {
                "sql" => new SqlDataRetriever(connectionStringOrBaseUrl),
                "http" => new HttpDataRetriever(CreateHttpClient(connectionStringOrBaseUrl), authenticator),
                _ => throw new ArgumentException("Invalid endpoint type", nameof(endpointType))
            };
        }

        private static HttpClient CreateHttpClient(string baseUrl)
        {
            var httpClient = new HttpClient()
            {
                BaseAddress = new Uri(baseUrl),
                Timeout = defaultOperationTimeout
            };
            return httpClient;
        }
    }
}
