/* Code generated by Azure.Iot.Operations.ProtocolCompiler; DO NOT EDIT. */

#nullable enable

namespace PTZ.dtmi_onvif_ptz__1
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using PTZ;

    public class Object_PTZStatus_MoveStatus
    {
        /// <summary>
        /// The 'PanTilt' Field.
        /// </summary>
        [JsonPropertyName("PanTilt")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public Enum_Onvif_Ptz_MoveStatus__1? PanTilt { get; set; } = default;

        /// <summary>
        /// The 'Zoom' Field.
        /// </summary>
        [JsonPropertyName("Zoom")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
        public Enum_Onvif_Ptz_MoveStatus__1? Zoom { get; set; } = default;

    }
}