# Azure IoT Operations connector for ONVIF PTZ demo

## Sample Application

This sample application demonstrates how to use the MRPC API provided by the connector for ONVIF to interact with an ONVIF device. The sample consists of two .NET assemblies:

- **PTZ**: This assembly contains code to interact with the PTZ service of an ONVIF device. It's generated from the PTZ service DTDL file.
- **Aio.Onvif.Connector.Ptz.Demo**: A simple console application that demonstrates how to use the PTZ assembly to move the camera.

## Build instructions
Make sure you have the .NET 8.0 SDK installed. You can download it for various platforms from the [Download .NET](https://dotnet.microsoft.com/download) site.

After it's installed, open this folder in your terminal and run `dotnet build`.

## Prerequisites

- An ONVIF compliant camera that supports PTZ operations. This sample was tested using a Tapo C210 camera.

- Azure IoT Operations deployed to your Kubernetes cluster. If you haven't deployed Azure IoT Operations yet, see [Quickstart: Run Azure IoT Operations Preview in GitHub Codespaces](https://learn.microsoft.com/azure/iot-operations/get-started-end-to-end-sample/quickstart-deploy) or [Azure IoT Operations deployment details](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/overview-deploy).

## Create custom resources

Create the following custom resources in your Kubernetes cluster to configure the connector for ONVIF.

To create a credentials secret for your ONVIF device, create a file called *credentials.yaml* with the following content. Add base64 encoded versions of your username and password in the `data` section:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: c210-1-credentials
data:
  username: # base64 encoded username for your ONVIF device
  password: # base64 encoded password for your ONVIF device
type: Opaque
```

> TIP: To encode a string to base64, you can use the following command: `echo -n 'your-string' | base64`.

Run the following command to create the credentials:

```bash
kubectl apply -f credentials.yaml
```

To cretae an asset endpoint for the ONVIF camera, create a file called *aep.yaml* with the following content. Add the URL of your ONVIF device in the `targetAddress` field. For the Tapo C210 camera, the URL looks like `http://<camera-ip>:2020/onvif/device_service`:

```yaml
apiVersion: deviceregistry.microsoft.com/v1
kind: AssetEndpointProfile
metadata:
  name: c210-4a826d41
spec:
  additionalConfiguration: |-
    {
      "$schema": "https://aiobrokers.blob.core.windows.net/aio-onvif-connector/1.0.0.json"
    }
  endpointProfileType: Microsoft.Onvif
  targetAddress: # The target address of the ONVIF device
  authentication:
    method: UsernamePassword
    usernamePasswordCredentials:
      usernameSecretName: c210-1-credentials/username # this refers to the secret created in the previous step
      passwordSecretName: c210-1-credentials/password # this refers to the secret created in the previous step
```

Run the following command to create the asset endpoint:

```bash
kubectl apply -f aep.yaml
```

To create a PTZ asset assigned to the asset endpoint you created in the previous step, create a file called *asset.yaml* with the following content:

```yaml	
apiVersion: deviceregistry.microsoft.com/v1
kind: Asset
metadata:
  name: c210-4a826d41-ptz # Important: the name must end with 'ptz'
spec:
  displayName: tapo C210
  assetEndpointProfileRef: c210-4a826d41 # this refers to the AEP created in the previous step
```

Run the following command to create the asset:

```bash
kubectl apply -f asset.yaml
```

## Retrieve profile token

Run the following powershell script to get the profile token you need to run the PTZ demo. Before you run the script, add your camera IP address, username, and password:

```powershell	
# Define the camera's IP address and credentials
$cameraIP = "<camera-ip>:2020" # Replace with your camera's IP address
$username = "<camera username>" # Replace with your camera's username
$password = "<camera password>" # Replace with your camera's password

# Define the ONVIF service URL
$onvifServiceURL = "http://$cameraIP/onvif/device_service"

# Create nonce and timestamp
$nonceBytes = [System.Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString())
$nonce = [System.Convert]::ToBase64String($nonceBytes)
$timestamp = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$timestampBytes = [System.Text.Encoding]::UTF8.GetBytes($timestamp)
$passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($password)
$combined = $nonceBytes + $timestampBytes + $passwordBytes
$combinedHashed = [System.Security.Cryptography.SHA1]::Create().ComputeHash($combined)
$combinedString = [System.Convert]::ToBase64String($combinedHashed)

# Create the XML request to get media profiles with wsse:UsernameToken
$requestXml = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <wsse:Security
      xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
      xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
      <wsse:UsernameToken>
        <wsse:Username>$username</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$combinedString</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">$nonce</wsse:Nonce>
        <wsu:Created>$timestamp</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>
  </s:Header>
  <s:Body>
    <GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
"@

# Set up the HTTP request headers
$headers = @{
    "Content-Type" = "application/soap+xml"
}

# Send the request to the ONVIF service
try {
    $response = Invoke-RestMethod -Uri $onvifServiceURL -Method Post -Headers $headers -Body $requestXml  -SkipHeaderValidation
    
    # Convert response to XmlDocument
    $responseXml = New-Object System.Xml.XmlDocument
    $responseXml.LoadXml($response.OuterXml)
    
    # Extract and display the media profile tokens from the response
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($responseXml.NameTable)
    $namespaceManager.AddNamespace("s", "http://www.w3.org/2003/05/soap-envelope")
    $namespaceManager.AddNamespace("trt", "http://www.onvif.org/ver10/media/wsdl")
    
    $profiles = $responseXml.SelectNodes("//trt:Profiles", $namespaceManager)
    
    foreach ($profile in $profiles) {
        $profileToken = $profile.Attributes["token"].Value
        Write-Output "Profile Token: $profileToken"
    }
} catch {
    Write-Output "Error: $_"
}
```

Make a note of the output from this script, you use it in a later step.

### Create a broker listener

Create a file called *broker-listener.yaml* with the following content:

```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1
kind: BrokerListener
metadata:
  name: test-listener
  namespace: azure-iot-operations
spec:
  brokerRef: default
  serviceType: LoadBalancer
  ports:
  - port: 1883
    protocol: Mqtt
```

> IMPORTANT: This configuration is for testing purposes only. In a production environment, use a secure connection.

Run the following command to create the broker listener:

```bash
kubectl apply -f broker-listener.yaml -n azure-iot-operations
```

### Update the Azure IoT Operations configuration

Update the Azure IoT Operations configuration to use the broker listener you created in the previous step:

```bash
kubectl set env deployment/aio-opc-supervisor opcuabroker_MqttOptions__MqttBroker=mqtt://test-listener.azure-iot-operations:1883 opcuabroker_MqttOptions__AuthenticationMethod=None -n azure-iot-operations
```

### Port forward the broker listener

Port forward the broker listener to your local machine in a second terminal:

```bash
kubectl port-forward svc/test-listener -n azure-iot-operations 1883:1883
```

Leave this shell open to keep the port forward active.

## Run the sample application

To start the sample application, run `dotnet run --project Aio.Onvif.Connector.Ptz.Demo`

The application prompts you for the following information:

- *Mqtt Broker Hostname and Port*: localhost and the port you forwarded in the previous step.
- *Azure IoT Operations Namespace*: 'azure-iot-operations' for a standard Azure IoT Operations deployment.
- *Asset Name*: The name of the PTZ asset that's assigned to the asset endpoint of the camera you want to move.
- *Profile Token*: the profile token from an earlier step.

After you enter this information, the application connects to the Azure IoT Operations MQ broker and you can move the camera with keyboard input. Press 'Q' to exit the application.

To verfiy that the camera is moving, you can connect to the camera's live stream by using a tool such as **VLC media player**. In the case of the Tapo C210 camera, you can use the following URL to connect to the RTSP stream: `rtsp://<camera-ip>/stream1`.

## Cleanup

To remove the resources created in the previous steps and restore the configuration, run the following commands:

```bash
kubectl delete secret c210-1-credentials
kubectl delete assetendpointprofile c210-4a826d41
kubectl delete asset c210-4a826d41-ptz
kubectl delete brokerlistener test-listener -n azure-iot-operations
kubectl set env deployment/aio-opc-supervisor opcuabroker_MqttOptions__MqttBroker=mqtts://aio-broker.azure-iot-operations:18883 opcuabroker_MqttOptions__AuthenticationMethod=ServiceAccountToken -n azure-iot-operations
```
