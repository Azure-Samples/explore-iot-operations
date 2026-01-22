// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

namespace OpcUaMqttRpc
{
    using System.Buffers;
    using Azure.Iot.Operations.Protocol;
    using Azure.Iot.Operations.Protocol.Models;

    public class CustomPayload : SerializedPayloadContext
    {
        public CustomPayload(ReadOnlySequence<byte> serializedPayload, string? contentType = "", MqttPayloadFormatIndicator payloadFormatIndicator = MqttPayloadFormatIndicator.Unspecified)
            : base(serializedPayload, contentType, payloadFormatIndicator)
        {
        }
    }
}
