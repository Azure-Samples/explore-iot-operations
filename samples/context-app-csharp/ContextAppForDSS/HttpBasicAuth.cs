namespace ContextualDataIngestor
{
    public class HttpBasicAuth : IAuthConfig
    {
        public required string Username { get; set; }
        public required string Password { get; set; }
    }
}
