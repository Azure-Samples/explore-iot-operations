# AIO ONVIF Connector PTZ Demo


# MRPC Sample Application

This sample application demonstrates how to use the MRPC API provided by ONVIF Connector to interact with an ONVIF device. The sample consists of 3 dotnet assemblies:
- PTZClient: This assembly contains code to interact with the PTZ service of an ONVIF device. It is generated from the PTZ service DTDL file.
- MediaClient: This assembly contains code to interact with the media service of an ONVIF device. It is generated from the media service DTDL file.
- Aio.Onvif.Connector.Ptz.Demo: A simple console application that demonstrates how to use the PTZ assembly to move the camera.

## Build instructions
Make sure you have the .NET 8.0 SDK installed. You can download it from [here](https://dotnet.microsoft.com/download).
Once installed open this directory in your terminal and run `dotnet build`

## Prerequisites

### Deploy ADR resources
#### Asset Endpoint Profile + Credentials

Deploy credentials secret for for device:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: camera-credentials
data:
  password: # base64 encoded password
  username: # base64 encoded username
type: Opaque

```

Execute the following to apply it to the cluster:

```bash
kubectl apply -f camera-credentials.yaml -n azure-iot-operations
```

Deploy AEP:

```yaml
apiVersion: deviceregistry.microsoft.com/v1
kind: AssetEndpointProfile
metadata:
  name: onvif-camera
spec:
  additionalConfiguration: |-
    {
      "$schema": "https://aiobrokers.blob.core.windows.net/aio-onvif-connector/1.0.0.json"
    }
  endpointProfileType: Microsoft.Onvif
  targetAddress: # device ip address
  authentication:
    method: UsernamePassword
    usernamePasswordCredentials:
      usernameSecretName: camera-credentials/username # this refers to the secret and it's data created in the previous step
      passwordSecretName: camera-credentials/password # this refers to the secret and it's data created in the previous step

```

Execute the following to apply it to the cluster:

```bash
kubectl apply -f broker-listener.yaml -n azure-iot-operations
```

#### PTZ Asset

Deploy PTZ asset:

```yaml	
apiVersion: deviceregistry.microsoft.com/v1
kind: Asset
metadata:
  name: onvif-camera-ptz # name must end with 'ptz'
spec:
  displayName: Onvif Camera (PTZ)
  assetEndpointProfileRef: onvif-camera # this refers to the AEP created in the previous step
  enabled: true
```

Execute the following to apply it to the cluster:

```bash
kubectl apply -f ptz-asset.yaml -n azure-iot-operations
```

#### Media Asset

Deploy Media asset:

```yaml
apiVersion: deviceregistry.microsoft.com/v1
kind: Asset
metadata:
  name: onvif-camera-media # name must end with 'media'
spec:
  displayName: Onvif Camera (Media)
  assetEndpointProfileRef: onvif-camera # this refers to the AEP created in the previous step
  enabled: true
```

Execute the following to apply it to the cluster:

```bash
kubectl apply -f media-asset.yaml -n azure-iot-operations
```

### Create Broker Listener

create a file called broker-listener.yaml with the following content:

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

Start the application by running `dotnet run --project Aio.Onvif.Connector.Ptz.Demo -- --mqtt-host localhost --mqtt-port 1883 --namespace azure-iot-operations --ptz-asset onvif-camera-ptz --media-asset onvif-camera-media --mode relative`

After entering this information, the application will connect to the AIO Broker and the camera can be moved with keyboard input. Press 'q' to exit the application.

This example uses RelativeMove by default. Depending on the camera, you may need to use ContinuousMove instead. To do this, add the `--mode continuous` option when starting the application.

## Cleanup

To remove the resources created in the previous steps and restore the configuration, run the following commands:

```bash
kubectl delete secret camera-credentials
kubectl delete assetendpointprofile onvif-camera
kubectl delete asset onvif-camera-ptz
kubectl delete asset onvif-camera-media
kubectl delete brokerlistener test-listener -n azure-iot-operations
```
