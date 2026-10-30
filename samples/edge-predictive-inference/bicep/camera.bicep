param customLocationName string
param adrNamespaceName string
param adrNamespaceLocation string
param cameraId string
param cameraUrl string
param cameraAuthentication object
param topicPrefix string
param enabled bool = false

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource adr 'Microsoft.DeviceRegistry/namespaces@2026-04-01' existing = {
  name: adrNamespaceName
}

resource device 'Microsoft.DeviceRegistry/namespaces/devices@2026-04-01' = {
  parent: adr
  name: cameraId
  location: adrNamespaceLocation
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    enabled: enabled
    endpoints: {
      inbound: {
        rtsp: {
          endpointType: 'Microsoft.Media'
          address: cameraUrl
          authentication: cameraAuthentication
        }
      }
    }
  }
}

resource asset 'Microsoft.DeviceRegistry/namespaces/assets@2026-04-01' = {
  parent: adr
  name: cameraId
  location: adrNamespaceLocation
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    enabled: enabled
    displayName: 'Continuous person-detection camera'
    deviceRef: {
      deviceName: device.name
      endpointName: 'rtsp'
    }
    streams: [
      {
        name: 'person-snapshots'
        streamConfiguration: '{"taskType":"snapshot-to-mqtt","autostart":true,"format":"jpeg","snapshotsPerSecond":0.2}'
        destinations: [
          {
            target: 'Mqtt'
            configuration: {
              topic: '${topicPrefix}/frames'
              qos: 'Qos1'
              retain: 'Never'
              ttl: 30
            }
          }
        ]
      }
    ]
  }
}
