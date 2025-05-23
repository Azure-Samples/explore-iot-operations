/* Code generated by Azure.Iot.Operations.ProtocolCompiler v0.9.0.0; DO NOT EDIT. */

#nullable enable

namespace PtzClient.Ptz
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using PtzClient;

    [System.CodeDom.Compiler.GeneratedCode("Azure.Iot.Operations.ProtocolCompiler", "0.9.0.0")]
    public partial class StopRequestPayload : IJsonOnDeserialized, IJsonOnSerializing
    {
        /// <summary>
        /// The Command request argument.
        /// </summary>
        [JsonPropertyName("Stop")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public Stop Stop { get; set; } = default!;

        void IJsonOnDeserialized.OnDeserialized()
        {
            if (Stop is null)
            {
                throw new ArgumentNullException("Stop field cannot be null");
            }
        }

        void IJsonOnSerializing.OnSerializing()
        {
            if (Stop is null)
            {
                throw new ArgumentNullException("Stop field cannot be null");
            }
        }
    }
}
