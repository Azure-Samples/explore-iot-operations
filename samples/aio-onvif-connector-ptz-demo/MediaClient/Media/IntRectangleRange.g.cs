/* Code generated by Azure.Iot.Operations.ProtocolCompiler v0.9.0.0; DO NOT EDIT. */

#nullable enable

namespace MediaClient.Media
{
    using System;
    using System.Collections.Generic;
    using System.Text.Json.Serialization;
    using MediaClient;

    [System.CodeDom.Compiler.GeneratedCode("Azure.Iot.Operations.ProtocolCompiler", "0.9.0.0")]
    public partial class IntRectangleRange : IJsonOnDeserialized, IJsonOnSerializing
    {
        /// <summary>
        /// Range of height.
        /// </summary>
        [JsonPropertyName("HeightRange")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public IntRange HeightRange { get; set; } = default!;

        /// <summary>
        /// Range of width.
        /// </summary>
        [JsonPropertyName("WidthRange")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public IntRange WidthRange { get; set; } = default!;

        /// <summary>
        /// Range of X-axis.
        /// </summary>
        [JsonPropertyName("XRange")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public IntRange Xrange { get; set; } = default!;

        /// <summary>
        /// Range of Y-axis.
        /// </summary>
        [JsonPropertyName("YRange")]
        [JsonIgnore(Condition = JsonIgnoreCondition.Never)]
        [JsonRequired]
        public IntRange Yrange { get; set; } = default!;

        void IJsonOnDeserialized.OnDeserialized()
        {
            if (HeightRange is null)
            {
                throw new ArgumentNullException("HeightRange field cannot be null");
            }
            if (WidthRange is null)
            {
                throw new ArgumentNullException("WidthRange field cannot be null");
            }
            if (Xrange is null)
            {
                throw new ArgumentNullException("XRange field cannot be null");
            }
            if (Yrange is null)
            {
                throw new ArgumentNullException("YRange field cannot be null");
            }
        }

        void IJsonOnSerializing.OnSerializing()
        {
            if (HeightRange is null)
            {
                throw new ArgumentNullException("HeightRange field cannot be null");
            }
            if (WidthRange is null)
            {
                throw new ArgumentNullException("WidthRange field cannot be null");
            }
            if (Xrange is null)
            {
                throw new ArgumentNullException("XRange field cannot be null");
            }
            if (Yrange is null)
            {
                throw new ArgumentNullException("YRange field cannot be null");
            }
        }
    }
}
