@description('Existing Azure IoT Operations instance.')
param aioInstanceName string
@description('Existing custom location for that instance.')
param customLocationName string
@description('New sample-owned data flow profile; do not reuse an unrelated profile.')
param dataflowProfileName string
@description('Existing registry endpoint with pull access to the camera artifacts.')
param registryEndpointName string
param artifactVersion string
param cameraAssetName string
param profileToken string
param topicPrefix string
@description('Qualify GetStatus first, then deploy all three independent data flow graphs.')
@allowed(['get-status', 'all'])
param actions string = 'get-status'

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

// Preview resource schemas must also be validated by ARM before deployment.
#disable-next-line BCP081
resource aio 'Microsoft.IoTOperations/instances@2026-11-01-preview' existing = {
  name: aioInstanceName
}

#disable-next-line BCP081
resource profile 'Microsoft.IoTOperations/instances/dataflowProfiles@2026-11-01-preview' = {
  parent: aio
  name: dataflowProfileName
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    instanceCount: 1
  }
}

var stages = actions == 'all' ? [
  { stage: 'get-status', action: 'GetStatus' }
  { stage: 'continuous-move', action: 'ContinuousMove' }
  { stage: 'stop', action: 'Stop' }
] : [
  { stage: 'get-status', action: 'GetStatus' }
]

#disable-next-line BCP081
resource graphs 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflowGraphs@2026-11-01-preview' = [for stage in stages: {
  parent: profile
  name: 'camera-${stage.stage}'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    mode: 'Enabled'
    requestDiskPersistence: 'Disabled'
    fileStores: []
    nodes: [
      {
        nodeType: 'Source'
        name: 'request'
        sourceSettings: {
          endpointRef: 'default'
          dataSources: ['${topicPrefix}/requests/${stage.action}']
        }
      }
      {
        nodeType: 'Graph'
        name: 'action'
        graphSettings: {
          registryEndpointRef: registryEndpointName
          artifact: 'azure-samples/aio-mcp-ai-assistant/camera-actions/${stage.stage}-graph:${artifactVersion}'
          configuration: [
            { key: 'asset_name', value: cameraAssetName }
            { key: 'profile_token', value: profileToken }
          ]
        }
      }
      {
        nodeType: 'Destination'
        name: 'response'
        destinationSettings: {
          endpointRef: 'default'
          dataDestination: '${topicPrefix}/responses/${stage.action}'
          headers: []
        }
      }
    ]
    nodeConnections: [
      { from: { name: 'request' }, to: { name: 'action.input' } }
      { from: { name: 'action.output' }, to: { name: 'response' } }
    ]
  }
}]

output profileId string = profile.id
