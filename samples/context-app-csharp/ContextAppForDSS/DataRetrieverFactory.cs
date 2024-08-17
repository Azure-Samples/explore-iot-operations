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
        public static IDataRetriever CreateDataRetriever(EndpointType endpointType, string connectionStringOrBaseUrl, IAuthConfig authConfig)
        {
            return endpointType switch
            {
                EndpointType.Sql => new SqlDataRetriever(connectionStringOrBaseUrl),
                EndpointType.Http => CreateHttpDataRetriever(connectionStringOrBaseUrl, authConfig),
                _ => throw new ArgumentException("Invalid endpoint type", nameof(endpointType))
            };
        }

        private static IDataRetriever CreateHttpDataRetriever(string connectionStringOrBaseUrl, IAuthConfig authConfig)
        {
            var retrievalRequest = new HttpRetrievalConfig
            {
                ConnectionStringOrBaseUrl = connectionStringOrBaseUrl,
                Endpoint = "contexts/quality",
                RequestBody = null,
                DataFormat = null,
                QueryParams = null,
            };
            return new HttpDataRetriever(retrievalRequest, authConfig);
        }
    }
}
