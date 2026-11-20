using System.Text.Json.Serialization;

namespace TelemetryPersister.Models
{
    public class CommandInfo
    {
        [JsonPropertyName("cmd")]
        public string? Command { get; set; }
    }
}
