// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Buffers;
using Azure.Iot.Operations.Protocol;
using Azure.Iot.Operations.Protocol.Models;

namespace mrpc.client.generated.v3
{
    public class CustomPayload : SerializedPayloadContext
    {
        public CustomPayload(ReadOnlySequence<byte> serializedPayload, string? contentType = "", MqttPayloadFormatIndicator payloadFormatIndicator = MqttPayloadFormatIndicator.Unspecified)
            : base(serializedPayload, contentType, payloadFormatIndicator)
        {
        }
    }
}
