// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace ContextualDataIngestor
{
    public class HttpBasicAuth : IAuthStrategy
    {
        public required string Username { get; set; }
        public required string Password { get; set; }
    }
}
