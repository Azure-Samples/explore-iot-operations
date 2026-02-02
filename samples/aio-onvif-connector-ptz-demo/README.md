# Azure IoT Operations ONVIF Connector PTZ Demo

## MRPC sample application

This sample application demonstrates how to use the MRPC API provided by the connector for ONVIF to interact with an ONVIF device. The sample consists of 3 dotnet assemblies:
- PTZClient: This assembly contains code to interact with the PTZ service of an ONVIF device. It's generated from the PTZ service DTDL file.
- MediaClient: This assembly contains code to interact with the media service of an ONVIF device. It's generated from the media service DTDL file.
- Aio.Onvif.Connector.Ptz.Demo: A simple console application that demonstrates how to use the PTZ assembly to move the camera.

## Prerequisites

### .NET SDK

Make sure you have the .NET 9.0 SDK installed. You can download it from [Download .NET](https://dotnet.microsoft.com/download).

After it's installed, open this directory in your terminal and run `dotnet build`

### Create the asset endpoint and assets

To create the asset endpoint and assets that the sample application interacts with, follow the steps in [Configure the connector for ONVIF](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-onvif-connector).

The how-to guide  walks you through the steps to create:

- The `my-onvif-camera` device with a inbound endpoint called `my-onvif-device-0`
- The discovered ONVIF and media assets

### Create Broker Listener

For the sample application to access the MQTT broker from outside the cluster, you need to create a listener that enables insecure connectivity to the broker from outside the cluster.

There are two options to achieve this:

- [Create a new broker listener with the NodePort service type](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection#node-port).
- [Create a new broker listener with the LoadBalancer service type](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-test-connection#load-balancer).

Tip: Use a [client MQTT tool](https://learn.microsoft.com/azure/iot-operations/troubleshoot/tips-tools#mqtt-tools) to verify connectivity to the broker using the created listener before you run the sample application.

Important: These configurations aren't secure and are only suitable in test and development environments. They enable an external client to connect to the internal MQTT broker without any credentials.

## Run instructions

Start the application by running `dotnet run --project Aio.Onvif.Connector.Ptz.Demo --mqtt-host localhost --mqtt-port 1883 --namespace azure-iot-operations --asset <your ONVIF asset name> --mode relative`

After entering this information, the application connects to the AIO Broker and the camera can be moved with keyboard input. Press 'q' to exit the application.

This example uses `RelativeMove` by default. Depending on the camera, you may need to use `ContinuousMove` instead. To do this, add the `--mode continuous` option when starting the application.

## Cleanup

To remove the resource created in the previous steps and restore the configuration, run the following command:

```bash
kubectl delete brokerlistener test-listener -n azure-iot-operations
```
