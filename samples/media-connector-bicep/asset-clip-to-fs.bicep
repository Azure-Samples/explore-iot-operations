metadata description = 'Media asset that saves clips to the file system.'

@description('The name of the custom location you are using.')
param customLocationName string

@description('Specifies the name of the asset endpoint resource to use.')
param aepName string

@description('The name of the asset you are creating.')
param assetName string = 'asset-clip-to-fs'

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
            name: 'clip-to-fs'
            dataSource: 'clip-to-fs'
            dataPointConfiguration: '{"taskType":"clip-to-fs","autostart":true,"realtime":true,"loop":true,"format":"avi","duration":3}'
          }
        ]
      }
    ]
  }
}
