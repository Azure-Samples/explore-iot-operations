# AIO ONVIF Connector PTZ Demo

## MRPC Sample Application

This sample application demonstrates how to use the MRPC API provided by ONVIF Connector to interact with an ONVIF device. The sample consists of 3 dotnet assemblies:
- PTZClient: This assembly contains code to interact with the PTZ service of an ONVIF device. It is generated from the PTZ service DTDL file.
- MediaClient: This assembly contains code to interact with the media service of an ONVIF device. It is generated from the media service DTDL file.
- Aio.Onvif.Connector.Ptz.Demo: A simple console application that demonstrates how to use the PTZ assembly to move the camera.

## Build instructions

Make sure you have the .NET 9.0 SDK installed. You can download it from [here](https://dotnet.microsoft.com/download).

Once installed open this directory in your terminal and run `dotnet build`

## Prerequisites

### Create the asset endpoint and assets

To create the asset endpoint and assets that the sample application interacts with, follow the steps in [Configure the connector for ONVIF (preview)](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-onvif-connector).

The how-to guide  walks you through the steps to create:

- The `my-onvif-camera` device with a inbound endpoint called `onvifep`
- The discovered ONVIF and media assets

### Create Broker Listener

Create a file called broker-listener.yaml with the following content:

```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1
kind: BrokerListener
metadata:
  name: test-listener
spec:
  brokerRef: default
  serviceType: LoadBalancer
  ports:
  - port: 1883
    protocol: Mqtt
```

Execute the following to apply it to the cluster:

```bash
kubectl apply -f broker-listener.yaml -n azure-iot-operations
```

### Port Forward Broker Listener

Port forward the broker listener to your local machine in a second terminal:

```bash
kubectl port-forward svc/test-listener -n azure-iot-operations 1883:1883
```

Leave this open to keep the port forward active.

## Run instructions

Start the application by running `dotnet run --project Aio.Onvif.Connector.Ptz.Demo -- --mqtt-host localhost --mqtt-port 1883 --namespace azure-iot-operations --ptz-asset <your ONVIF asset name> --media-asset <your media asset name> --mode relative`

After entering this information, the application will connect to the AIO Broker and the camera can be moved with keyboard input. Press 'q' to exit the application.

This example uses RelativeMove by default. Depending on the camera, you may need to use ContinuousMove instead. To do this, add the `--mode continuous` option when starting the application.

## Cleanup

To remove the resource created in the previous steps and restore the configuration, run the following command:

```bash
kubectl delete brokerlistener test-listener -n azure-iot-operations
```
