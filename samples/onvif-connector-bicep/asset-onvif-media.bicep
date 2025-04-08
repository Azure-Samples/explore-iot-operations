metadata description = 'ONVIF camera media capabilities'
param aepName  string
param customLocationName string
param assetName     string = 'camera-media'
param displayName string = 'Camera media service'

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
