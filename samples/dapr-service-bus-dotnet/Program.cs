using System.Text;
using System.Text.Json;
using Dapr;
using Dapr.Client;

internal class Program
{
    const string pubSubName = "aio-mq-pubsub";
    const string serviceBusName = "servicebus-binding";

    private static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        builder.Logging.ClearProviders();
        builder.Logging.AddConsole();

        var app = builder.Build();

        // needed for Dapr pub/sub routing, plus enable raw mode
        app.MapSubscribeHandler(new Dapr.SubscribeOptions() { 
            EnableRawPayload = true,
        });

        // Dapr subscription in [Topic] routes orders topic to this route
        app.MapPost("/servicebus", [Topic(pubSubName, "servicebus")] async (JsonDocument json) => {
            // the payload is base64 encoded
            var payload64 = json.RootElement.GetProperty("data_base64").ToString();
            var payload = Encoding.UTF8.GetString(Convert.FromBase64String(payload64));

		    app.Logger.LogInformation("event: data:" + payload);

            using var client = new DaprClientBuilder().Build();
            await client.InvokeBindingAsync(bindingName: serviceBusName, operation: "create", data: payload);

		    app.Logger.LogInformation("event: Sent message to service bus");

            return Results.Ok();
        });

        app.Run("http://localhost:6001");
    }
}
