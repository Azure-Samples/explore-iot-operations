using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;

namespace ContextualDataIngestor
{
    public class BasicAuthenticator : IAuthConfig
    {
        private readonly string _username;
        private readonly string _password;

        public BasicAuthenticator(string username, string password)
        {
            _username = username ?? throw new ArgumentNullException(nameof(username));
            _password = password ?? throw new ArgumentNullException(nameof(password));
        }

        public void ApplyAuthentication(HttpClient httpClient)
        {
            var byteArray = Encoding.ASCII.GetBytes($"{_username}:{_password}");
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(byteArray));
        }
    }
}
