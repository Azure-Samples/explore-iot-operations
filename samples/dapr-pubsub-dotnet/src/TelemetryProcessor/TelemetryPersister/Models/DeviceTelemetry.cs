using System.Text.Json.Serialization;

namespace TelemetryPersister.Models
{
    public class DeviceTelemetry
    {
        [JsonPropertyName("deviceId")]
        public string? DeviceId{ get; set; }
        [JsonPropertyName("timestamp")]
        public DateTimeOffset Timestamp { get; set; }
        [JsonPropertyName("tag")]
        public string? Tag { get; set; }
        [JsonPropertyName("value")]
        public object? Value { get; set; }
    }
}
