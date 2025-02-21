metadata description = 'Media asset that streams RTSP to a media server.'

@description('The name of the custom location you are using.')
param customLocationName string

@description('Specifies the name of the asset endpoint resource to use.')
param aepName string

@description('The name of the asset you are creating.')
param assetName string = 'asset-stream-to-rtsp'

@description('The IP address of your media server.')
param mediaServerAddress string

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
            name: 'stream-to-rtsp'
            dataSource: 'stream-to-rtsp'
            dataPointConfiguration: '{"taskType":"stream-to-rtsp","autostart":true,"realtime":true,"loop":true,"media_server_address":"${mediaServerAddress}"}'
          }
        ]
      }
    ]
  }
}
