metadata description = 'ONVIF camera device events'
param aepName  string
param customLocationName string
param assetName     string = 'camera-device'
param displayName string = 'Camera device motion detected'

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
    enabled: true
    events: [
      {
        eventNotifier: 'tns1:RuleEngine/CellMotionDetector/Motion'
        name: 'motionDetected'
      }
    ]
  }
}
