using System.Net.Http;

namespace ContextualDataIngestor
{
    public interface IAuthenticator
    {
        void ApplyAuthentication(HttpClient httpClient);
    }
}
