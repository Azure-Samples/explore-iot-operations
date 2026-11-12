param customLocationName string
param adrNamespaceName string
param adrNamespaceLocation string
param sampleNamespace string
param cameraEndpointUrl string
param cameraCredentialSecretName string
param cameraDeviceName string = 'edge-assistant-camera'
param cameraAssetName string = 'edge-assistant-camera-onvif'

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

// Preview schemas are validated by ARM when validating and deploying this template.
#disable-next-line BCP081
resource adr 'Microsoft.DeviceRegistry/namespaces@2026-04-01' existing = {
  name: adrNamespaceName
}

#disable-next-line BCP081
resource device 'Microsoft.DeviceRegistry/namespaces/devices@2026-04-01' = {
  parent: adr
  name: cameraDeviceName
  location: adrNamespaceLocation
  tags: {
    sample: 'aio-mcp-ai-assistant'
    sampleInstance: sampleNamespace
  }
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    enabled: true
    endpoints: {
      inbound: {
        onvif: {
          endpointType: 'Microsoft.Onvif'
          address: cameraEndpointUrl
          authentication: {
            method: 'UsernamePassword'
            usernamePasswordCredentials: {
              usernameSecretName: '${cameraCredentialSecretName}/username'
              passwordSecretName: '${cameraCredentialSecretName}/password'
            }
          }
        }
      }
    }
  }
}

#disable-next-line BCP081
resource asset 'Microsoft.DeviceRegistry/namespaces/assets@2026-04-01' = {
  parent: adr
  name: cameraAssetName
  location: adrNamespaceLocation
  tags: {
    sample: 'aio-mcp-ai-assistant'
    sampleInstance: sampleNamespace
  }
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    enabled: true
    displayName: 'Operations assistant camera PTZ controls'
    deviceRef: {
      deviceName: device.name
      endpointName: 'onvif'
    }
    managementGroups: [
      {
        name: 'PTZ'
        typeRef: 'http://www.onvif.org/ver20/ptz/wsdl'
        actions: [for action in ['ContinuousMove', 'Stop', 'GetStatus']: {
          name: action
          actionType: 'Call'
          targetUri: action
          typeRef: action
          topic: 'azure-iot-operations/asset-operations/${cameraAssetName}/PTZ/${action}'
        }]
      }
    ]
  }
}

output deviceId string = device.id
output assetId string = asset.id
