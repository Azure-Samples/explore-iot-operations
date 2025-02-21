metadata description = 'Asset endpoint profile for media connector'

@description('The RTSP endpoint for the media stream.')
param targetAddress string

@description('The name of the custom location you are using.')
param customLocationName string

@description('Specifies the name of the asset endpoint resource to create.')
param aepName string

@description('The name of the Kubernetes secret you are using.')
param secretName string

/*****************************************************************************/
/*                          Asset endpoint profile                           */
/*****************************************************************************/
resource assetEndpoint 'Microsoft.DeviceRegistry/assetEndpointProfiles@2024-11-01' = {
  name: aepName
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationName
  }
  properties: {
    targetAddress: targetAddress
    endpointProfileType: 'Microsoft.Media'
    #disable-next-line no-hardcoded-env-urls //Schema required during public preview
    additionalConfiguration: '{"@schema":"https://aiobrokers.blob.core.windows.net/aio-media-connector/1.0.0.json"}'
    authentication: {
      method: 'UsernamePassword'
      usernamePasswordCredentials: {
        passwordSecretName: '${secretName}/password'
        usernameSecretName: '${secretName}/username'
        }
    }
  }
}
