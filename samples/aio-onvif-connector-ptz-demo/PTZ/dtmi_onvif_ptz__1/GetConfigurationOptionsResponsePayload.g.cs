/* Code generated by Azure.Iot.Operations.ProtocolCompiler; DO NOT EDIT. */

#nullable enable

namespace PTZ.dtmi_onvif_ptz__1
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using PTZ;

    public class GetConfigurationOptionsResponsePayload : IJsonOnDeserialized, IJsonOnSerializing
    {
        /// <summary>
        /// The Command response argument.
        /// </summary>
        [JsonPropertyName("GetConfigurationOptionsResponse")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public Object_Onvif_Ptz_GetConfigurationOptionsResponse__1 GetConfigurationOptionsResponse { get; set; } = default!;

        void IJsonOnDeserialized.OnDeserialized()
        {
            if (GetConfigurationOptionsResponse is null)
            {
                throw new ArgumentNullException("GetConfigurationOptionsResponse field cannot be null");
            }
        }

        void IJsonOnSerializing.OnSerializing()
        {
            if (GetConfigurationOptionsResponse is null)
            {
                throw new ArgumentNullException("GetConfigurationOptionsResponse field cannot be null");
            }
        }
    }
}
