namespace ContextualDataIngestor
{
    public class AppAdditionalConfiguration
    {
        public DataSourceType DataSourceType { get; set; }
        public int RequestIntervalInSeconds { get; set; }
        public string? DssKey { get; set; }
        public string? HttpPath { get; set; }
        public string? SqlDatabaseName { get; set; }
        public string? SqlTableName { get; set; }
        public string? MqttClientId { get; set; }
    }
}