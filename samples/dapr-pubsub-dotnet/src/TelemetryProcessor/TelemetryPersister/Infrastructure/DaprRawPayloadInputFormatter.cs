using Microsoft.AspNetCore.Mvc.Formatters;

namespace TelemetryPersister.Infrastructure
{
    /// <summary>
    /// An InputFormatter that is responsible for formatting the raw byte-stream payloads that are transferred
    /// by Dapr to a typed model that the ASP.NET controller expects.
    /// </summary>
    /// <remarks>This InputFormatter is required to overcome the HTTP 415 'media type not supported' error.
    /// See also this issue on Github: https://github.com/dapr/dotnet-sdk/issues/989
    /// </remarks>
    public class DaprRawPayloadInputFormatter : InputFormatter
    {
        public DaprRawPayloadInputFormatter()
        {
            SupportedMediaTypes.Add("application/octet-stream");
        }

        public override async Task<InputFormatterResult> ReadRequestBodyAsync(InputFormatterContext context)
        {
            using (MemoryStream str = new MemoryStream())
            {
                try
                {
                    await context.HttpContext.Request.Body.CopyToAsync(str);

                    var jsonString = System.Text.Encoding.UTF8.GetString(str.ToArray());

                    var deserializedModel = System.Text.Json.JsonSerializer.Deserialize(jsonString, context.ModelType);

                    return InputFormatterResult.Success(deserializedModel);
                }
                catch (Exception ex)
                {
                    Console.WriteLine(ex.Message);
                    return InputFormatterResult.Failure();
                }
            }
        }
    }
}