metadata description = 'ONVIF camera PTZ capabilities'
param aepName  string
param customLocationName string
param assetName     string = 'camera-ptz'
param displayName string = 'Camera PTZ service'

/*****************************************************************************/
/*                                    Asset                                  */
/*****************************************************************************/
resource asset 'Microsoft.DeviceRegistry/assets@2024-11-01' = {
  name: assetName
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationName
  }
  properties: {
    displayName: displayName
    assetEndpointProfileRef: aepName
  }
}
