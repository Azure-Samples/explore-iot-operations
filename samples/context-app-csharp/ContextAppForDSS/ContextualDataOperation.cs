using Akri.Mq.StateStore;
using ContextualDataIngestor;
using Microsoft.Extensions.Logging;

namespace ContextAppForDSS
{
    internal class ContextualDataOperation
    {
        private IStateStoreClient _stateStoreClient;
        private IDataRetriever _dataRetriever;
        private ILogger _logger;
        private int _intervalSeconds;
        private string _stateStoreKey;
        public ContextualDataOperation(IStateStoreClient stateStoreClient, IDataRetriever dataRetriever, string stateStoreKey, int intervalSeconds)
        {
            _stateStoreClient = stateStoreClient;
            _dataRetriever = dataRetriever;
            _intervalSeconds = intervalSeconds;
            _stateStoreKey = stateStoreKey;
            // Create LoggerFactory and ILogger
            using var loggerFactory = LoggerFactory.Create(builder =>
            {
                builder.AddConsole();
            });
            _logger = loggerFactory.CreateLogger<ContextualDataOperation>();
        }
        public async Task PopulateContextualDataLoopAsync()
        {
            while (true)
            {
                try
                {
                    string stateStoreValue = await _dataRetriever.RetrieveDataAsync();
                    _logger.LogInformation("Store data in Distributed State Store");
                    await StoreDataAsync(stateStoreValue);
                }
                catch (Exception e)
                {
                    _logger.LogError("Error retrieving or storing data: " + e.Message);
                }

                await Task.Delay(TimeSpan.FromSeconds(_intervalSeconds));

                _logger.LogInformation("Processing complete.");
            }

        }

        private async Task StoreDataAsync(string stateStoreValue)
        {
            StateStoreSetResponse setResponse =
                await _stateStoreClient.SetAsync(_stateStoreKey, stateStoreValue);

            if (setResponse.Success)
            {
                _logger.LogInformation($"Successfully set key {_stateStoreKey} with value {stateStoreValue}");
            }
            else
            {
                _logger.LogError($"Failed to set key {_stateStoreKey} with value {stateStoreValue}");
            }
        }
    }
}
