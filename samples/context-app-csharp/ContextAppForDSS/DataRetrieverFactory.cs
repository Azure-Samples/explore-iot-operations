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
        public static IDataRetriever CreateDataRetriever(EndpointType endpointType, string connectionStringOrBaseUrl, IAuthenticator authenticator = null)
        {
            return endpointType switch
            {
                EndpointType.Sql => new SqlDataRetriever(connectionStringOrBaseUrl),
                EndpointType.Http => new HttpDataRetriever(connectionStringOrBaseUrl, authenticator),
                _ => throw new ArgumentException("Invalid endpoint type", nameof(endpointType))
            };
        }
    }
}
