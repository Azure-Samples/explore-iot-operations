/* Code generated by Azure.Iot.Operations.ProtocolCompiler; DO NOT EDIT. */

#nullable enable

namespace PTZ.dtmi_onvif_ptz__1
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using PTZ;

    public class RemovePresetRequestPayload : IJsonOnDeserialized, IJsonOnSerializing
    {
        /// <summary>
        /// The Command request argument.
        /// </summary>
        [JsonPropertyName("RemovePreset")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public Object_Onvif_Ptz_RemovePreset__1 RemovePreset { get; set; } = default!;

        void IJsonOnDeserialized.OnDeserialized()
        {
            if (RemovePreset is null)
            {
                throw new ArgumentNullException("RemovePreset field cannot be null");
            }
        }

        void IJsonOnSerializing.OnSerializing()
        {
            if (RemovePreset is null)
            {
                throw new ArgumentNullException("RemovePreset field cannot be null");
            }
        }
    }
}