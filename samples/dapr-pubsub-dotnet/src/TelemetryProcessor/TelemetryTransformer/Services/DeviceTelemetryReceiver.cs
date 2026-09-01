using Dapr.AppCallback.Autogen.Grpc.v1;
using Dapr.Client;
using Dapr.Client.Autogen.Grpc.v1;
using Google.Protobuf.WellKnownTypes;
using Grpc.Core;
using Microsoft.Extensions.Logging;
using System.Text;
using System.Text.Json;
using TelemetryTransformer.Models;

namespace TelemetryTransformer.Services
{
    internal class DeviceTelemetryReceiver : AppCallback.AppCallbackBase
    {
        private readonly ILogger<DeviceTelemetryReceiver> _logger;
        private readonly DaprClient _daprClient;

        public DeviceTelemetryReceiver(DaprClient daprClient, ILogger<DeviceTelemetryReceiver> logger)
        {
            _logger = logger;
            _daprClient = daprClient;
        }

        public override Task<InvokeResponse> OnInvoke(InvokeRequest request, ServerCallContext context)
        {
            _logger.LogTrace("Request.Method: " + request.Method);

            _logger.LogTrace("Context.Method:" + context.Method);
            _logger.LogTrace("Context.Host:" + context.Host);
            _logger.LogTrace("Context.Peer:" + context.Peer);

            foreach (var h in context.RequestHeaders)
            {
                _logger.LogTrace(h.Key + "=" + h.Value);
            }

            return Task.FromResult(new InvokeResponse());
        }

        public override Task<ListTopicSubscriptionsResponse> ListTopicSubscriptions(Empty request, ServerCallContext context)
        {
            var result = new ListTopicSubscriptionsResponse();

            var vesselTelemetrySubscription = new TopicSubscription
            {
                PubsubName = "telemetrypubsub",
                Topic = "devices/+/#",
            };
            vesselTelemetrySubscription.Metadata.Add("rawPayload", "true");

            result.Subscriptions.Add(vesselTelemetrySubscription);

            return Task.FromResult(result);
        }

        public override async Task<TopicEventResponse> OnTopicEvent(TopicEventRequest request, ServerCallContext context)
        {
            _logger.LogInformation("OnTopicEvent called on topic {0}", request.Topic);
            _logger.LogInformation("payload = " + request.Data.ToStringUtf8());

            await ProcessTelemetryAsync(request, _daprClient);


            return new TopicEventResponse() { Status = TopicEventResponse.Types.TopicEventResponseStatus.Success };
        }

        private async Task<TopicEventResponse> ProcessTelemetryAsync(TopicEventRequest message, DaprClient daprClient)
        {
            string deviceId;

            try
            {
                deviceId = RetrieveDeviceIdFromTopic(message.Topic);
            }
            catch (InvalidOperationException ex)
            {
                _logger.LogError(ex, "Unable to process message");
                return new TopicEventResponse() { Status = TopicEventResponse.Types.TopicEventResponseStatus.Drop };
            }

            var deserializedMessage = DeserializeReceivedMessage(message.Data.ToByteArray());

            if (deserializedMessage == null)
            {
                _logger.LogError("Unable to process message with body " + message.Data.ToStringUtf8());
                return new TopicEventResponse() { Status = TopicEventResponse.Types.TopicEventResponseStatus.Drop };
            }

            var vesselTelemetryMessage = new DeviceTelemetry()
            {
                DeviceId = deviceId,
                Tag = deserializedMessage.Tag,
                Value = deserializedMessage.Value,
                Timestamp = deserializedMessage.Timestamp
            };

            try
            {
                _logger.LogInformation("Publishing message ...");

                await daprClient.PublishEventAsync<DeviceTelemetry>(
                    "telemetrypubsub",
                    "devicetelemetry",
                    data: vesselTelemetryMessage);

                var toCloudMetaData = new Dictionary<string, string>()
                {
                    ["rawPayload"] = "true"
                };

                await daprClient.PublishEventAsync<DeviceTelemetry>(
                    "telemetrypubsub",
                    "telemetry_tocloud",
                    data: vesselTelemetryMessage,
                    metadata: toCloudMetaData);

                _logger.LogInformation("Message published.");

                return new TopicEventResponse() { Status = TopicEventResponse.Types.TopicEventResponseStatus.Success };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error occurred");
                return new TopicEventResponse() { Status = TopicEventResponse.Types.TopicEventResponseStatus.Retry };
            }
        }

        private static string RetrieveDeviceIdFromTopic(string topic)
        {
            var parts = topic.Split('/');

            if (parts.Length != 3)
            {
                throw new InvalidOperationException("Message received on invalid topic");
            }

            return parts[1];
        }

        private static ReceivedMessage? DeserializeReceivedMessage(byte[] message)
        {
            Console.WriteLine("Received message: " + Encoding.UTF8.GetString(message));

            var deserializedMessage = JsonSerializer.Deserialize<ReceivedMessage>(message);

            Console.WriteLine("Message deserialized: ");
            Console.WriteLine($"Timestamp = {deserializedMessage.Timestamp}");
            Console.WriteLine($"Tag = {deserializedMessage.Tag}");
            Console.WriteLine($"Value = {deserializedMessage.Value}");

            return deserializedMessage;
        }

        private class ReceivedMessage
        {
            public DateTimeOffset Timestamp { get; set; }
            public string Tag { get; set; }
            public object Value { get; set; }
        }
    }
}
