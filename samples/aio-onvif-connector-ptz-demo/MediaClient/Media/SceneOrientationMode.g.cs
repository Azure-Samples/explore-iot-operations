/* Code generated by Azure.Iot.Operations.ProtocolCompiler v0.9.0.0; DO NOT EDIT. */

#nullable enable

namespace MediaClient.Media
{
    using System.Runtime.Serialization;
    using System.Text.Json.Serialization;

    [JsonConverter(typeof(JsonStringEnumMemberConverter))]
    [System.CodeDom.Compiler.GeneratedCode("Azure.Iot.Operations.ProtocolCompiler", "0.9.0.0")]
    public enum SceneOrientationMode
    {
        [EnumMember(Value = @"AUTO")]
        Auto = 0,
        [EnumMember(Value = @"MANUAL")]
        Manual = 1,
        [EnumMember(Value = @"Unknown")]
        Unknown = 2,
    }
}
