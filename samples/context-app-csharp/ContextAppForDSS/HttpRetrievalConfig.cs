namespace ContextualDataIngestor
{
    internal class HttpRetrievalConfig
    {
        public required string ConnectionStringOrBaseUrl { get; set; }
        public required string Endpoint { get; set; }
        public string? RequestBody { get; set; }
        public string? DataFormat { get; set; }
        public string? QueryParams { get; set; }
    }
}