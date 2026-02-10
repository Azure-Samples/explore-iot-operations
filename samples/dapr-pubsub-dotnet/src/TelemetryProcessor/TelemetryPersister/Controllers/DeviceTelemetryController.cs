using Dapr;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;
using Dapr.Client;
using TelemetryPersister.Models;

namespace TelemetryPersister.Controllers
{
    [Route("api/[controller]")]
    [ApiController]
    public class DeviceTelemetryController : ControllerBase
    {
        private readonly ILogger<DeviceTelemetryController> _logger;
        private readonly DaprClient _daprClient;

        private static readonly JsonSerializerOptions SerializerOptions = new JsonSerializerOptions
        {
            WriteIndented = false
        };

        public DeviceTelemetryController(DaprClient daprClient, ILogger<DeviceTelemetryController> logger)
        {
            _daprClient = daprClient;
            _logger = logger;
        }

        [Topic(pubsubName: "telemetrypubsub", name: "devicetelemetry")]
        [HttpPost("/devicetelemetery")]
        public ActionResult ReceiveVesselTelemetry([FromBody] DeviceTelemetry message)
        {
            _logger.LogInformation("DeviceTelemetry message received");
            _logger.LogInformation($"Persisting telemetry for device: {JsonSerializer.Serialize(message, SerializerOptions)}");

            return Ok();
        }

        [Topic(pubsubName: "telemetrypubsub", name: "commands/#", enableRawPayload: true)]
        [HttpPost("/devicecommands")]
        public ActionResult ReceiveVesselCommand([FromBody] CommandInfo cmd )
        {
            _logger.LogInformation("CommandInfo received: " + cmd.Command);

            return Ok();
        }
    }
}
