metadata description = 'Media asset that publishes snapshots to MQTT.'

@description('The name of the custom location you are using.')
param customLocationName string

@description('Specifies the name of the asset endpoint resource to use.')
param aepName string

@description('The name of the asset you are creating.')
param assetName string = 'asset-snapshot-to-mqtt'

/*****************************************************************************/
/*                          Asset                                            */
/*****************************************************************************/
resource asset 'Microsoft.DeviceRegistry/assets@2024-11-01' = {
  name: assetName
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationName
  }
  properties: {
    assetEndpointProfileRef: aepName
    datasets: [
      {
        name: 'dataset1'
        dataPoints: [
          {
            name: 'snapshot-to-mqtt'
            dataSource: 'snapshot-to-mqtt'
            dataPointConfiguration: '{"taskType":"snapshot-to-mqtt","autostart":true,"realtime":true,"loop":true,"format":"jpeg","fps":1}'
          }
        ]
      }
    ]
  }
}
