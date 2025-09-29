namespace Aio.Connectors.OpcUa.Demo;

using Azure.Iot.Operations.Protocol;
using static mrpc.client.generated.v3.Write.Write;

/// <summary>
/// Client to write datasets.
/// </summary>
public class WriteDatasetClient : Client
{
    /// <summary>
    /// Initializes a new instance of the <see cref="WriteDatasetClient"/> class.
    /// </summary>
    public WriteDatasetClient(
        ApplicationContext applicationContext,
        IMqttPubSubClient mqttClient,
        string aioNamespace,
        string assetName,
        string datasetName)
        : base(
            applicationContext,
            mqttClient,
            new Dictionary<string, string>
            {
                { "namespace", aioNamespace },
                { "asset", assetName },
                { "dataset", datasetName },
            })
    {
        // SDK don't listens to dynamic response topic ==> https://github.com/Azure/iot-operations-sdks/issues/638
        WriteDatasetCommandInvoker.ResponseTopicPattern = "responseTopic/" + Guid.NewGuid().ToString();

        // WriteDatasetCommandInvoker.GetResponseTopic = (string requestTopic) => {
        //     return "responseTopic/" + Guid.NewGuid().ToString();
        // };
        //// WriteDatasetCommandInvoker.TopicTokenMap["ex:namespace"] = aioNamespace;
        //// WriteDatasetCommandInvoker.TopicTokenMap["ex:asset"] = assetName;
        //// WriteDatasetCommandInvoker.TopicTokenMap["ex:dataset"] = datasetName;
        //// WriteDatasetCommandInvoker.TopicTokenMap["namespace"] = aioNamespace;
        //// WriteDatasetCommandInvoker.TopicTokenMap["asset"] = assetName;
        //// WriteDatasetCommandInvoker.TopicTokenMap["dataset"] = datasetName;

        //// CustomTopicTokenMap["ex:namespace"] = aioNamespace;
        //// CustomTopicTokenMap["ex:asset"] = assetName;
        //// CustomTopicTokenMap["ex:dataset"] = datasetName;
        //// CustomTopicTokenMap["namespace"] = aioNamespace;
        //// CustomTopicTokenMap["asset"] = assetName;
        //// CustomTopicTokenMap["dataset"] = datasetName;
    }
}