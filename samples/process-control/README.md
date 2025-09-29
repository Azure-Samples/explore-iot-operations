# OPC UA process control

In Azure IoT Operations `aio-opc-ua-commander` lets you send changes to an OPC UA server from the edge or from the cloud. The current preview includes support for writing data points from an asset dataset with simple and complex data-types as well as dumping the address space of an OPC UA server.

The OPC-UA commander:

- Uses the [RPC](https://github.com/Azure/iot-operations-sdks/blob/main/doc/reference/rpc-protocol.md) and MQTT protocol/broker as the underlying messaging plane.
  MQTT messages include some system and user properties to define [metadata](https://github.com/Azure/iot-operations-sdks/blob/main/doc/reference/message-metadata.md) values that help with flow control.
- Subscribes to MQTT topic `{AioNamespace}/asset-operations/{AssetId}/{DatasetName}/` for data-set write operations.
- Subscribes to MQTT topic `{AioNamespace}/asset-operations/{AssetId}/{ManagementGroupName}/` for call operations and explicit write.
- Subscribes to MQTT topic `{AioNamespace}/endpoint-operations/{InboundEndpointProfileName}/{ActionName}/` for endpoint operations.
- On MQTT request/response create ad-hoc session based on the device associated with the namespace asset.
- Validates write requests against the generated request schema.
- Validates that the write request only contains data points that exist within the dataset.
- Use write service calls to set all data-points at once.
- Sends response to response topic property defined in MQTT message.

To learn more about how `aio-opc-ua-commander` works, see [How to control OPC UA assets](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-control-opc-ua).

This sample illustrates some of these capabilities using the OPC PLC simulator boiler.

## Prerequisites

To run the sample application, you need:

- A preview instance of Azure IoT Operations deployed. If you don't already have an instance, see [Create an Azure IoT Operations instance](https://learn.microsoft.com/azure/iot-operations/get-started-end-to-end-sample/quickstart-deploy).
- Access to the internal MQTT broker in the Azure IoT Operations cluster. To configure access the broker, see [Test connectivity to MQTT broker with MQTT clients](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection).
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) version 2.67.0 or higher.
- [NET 9 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/9.0)

## Deploy the simulator

The sample application uses the boiler in the OPC PLC simulator.

To deploy the OPC PLC simulator, run the following command:

```bash
kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/opc-plc-deployment.yaml
```

> [!CAUTION]
> This configuration uses a self-signed application instance certificate. Don't use this configuration in a production environment. To learn more, see [Configure OPC UA certificates infrastructure for the connector for OPC UA](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-configure-opc-ua-certificates-infrastructure).


## Configure the device and namespace assets

To add the required device (`opc-ua-commander`), inbound endpoint (`opc-ua-commander-0`), and namespace asset (`boiler`) to your instance, run the following commands:

```bash
wget https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/process-control/boiler-simulation.bicep -O boiler-simulation.bicep

AIO_NAMESPACE_NAME=<YOUR_AIO_NAMESPACE_NAME>
RESOURCE_GROUP=<YOUR_RESOURCE_GROUP_NAME>
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
CUSTOM_LOCATION_NAME=$(az iot ops list -g $RESOURCE_GROUP --query "[0].extendedLocation.name" -o tsv | awk -F'/' '{print $NF}')

az deployment group create --subscription $SUBSCRIPTION_ID --resource-group $RESOURCE_GROUP --template-file boiler-simulation.bicep --parameters customLocationName=$CUSTOM_LOCATION_NAME aioNamespaceName=$AIO_NAMESPACE_NAME
```

You can review these resources in the Operations experience web UI or by running the following commands:

```bash
# View device details
az iot ops ns device query --instance <your instance name> -g <your resource group>
# View namespace asset details
az iot ops ns asset query --instance <your instance name> -g <your resource group>
```

## Configure and run application

Make sure the `process-control-demo/src/write.dataset.client/appsettings.json` file contains the correct values for:

- `HostName` and `Port` in the `ConnectionStrings` setting.
- `Namespace`: typically `azure-iot-operations`.
- `AssetName`: `boiler` if you used the `boiler-simulation.bicep` file to add the device and namespace asset.
- `DatasetName`: `default` if you used the `boiler-simulation.bicep` file to add the device and namespace asset.

To run the application:

```bash
dotnet run --project process-control-demo/src/write.dataset.client/write.dataset.client.csproj
```

### Usage

For example, to set the `TargetTemperature` and other values on the boiler asset, the sample application publishes the following MQTT message to the topic `azure-iot-operations/asset-operations/<asset name>/<dataset name>`:

```json
{
    "BaseTemperature": 42,
    "MaintenanceInterval": 360,
    "OverheatInterval": 45,
    "OverheatedThresholdTemperature": 199,
    "TargetTemperature": 176,
    "TemperatureChangeSpeed": 6
}
```

The OPC UA commander service in the cluster subscribes to this topic, receives the message, and writes the values to the OPC UA server. The commander service then publishes the result of the write operation to the topic `responseTopic`. If the operation succeeds, the message in the response topic looks like `{}`.
