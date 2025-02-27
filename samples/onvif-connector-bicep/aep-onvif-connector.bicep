metadata description = 'Asset endpoint profile for ONVIF connector'

@description('The ONVIF discovery endpoint.')
param onvifAddress string

@description('The name of the custom location you are using.')
param customLocationName string

@description('Specifies the name of the asset endpoint resource to create.')
param aepName string

@description('The name of the Kubernetes secret you are using to store the camera credentials.')
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
    targetAddress: onvifAddress
    endpointProfileType: 'Microsoft.Onvif'
    #disable-next-line no-hardcoded-env-urls //Schema required during public preview
    additionalConfiguration: '{"@schema":"https://aiobrokers.blob.core.windows.net/aio-onvif-connector/1.0.0.json"}'
    authentication: {
      method: 'UsernamePassword'
      usernamePasswordCredentials: {
        passwordSecretName: '${secretName}/password'
        usernameSecretName: '${secretName}/username'
      }
    }
  }
}
