namespace TelemetryTransformer.Models
{
    public class DeviceTelemetry
    {
        public string DeviceId { get; set; }
        public DateTimeOffset Timestamp { get; set; }
        public string Tag { get; set; }
        public object Value { get; set; }
    }
}
