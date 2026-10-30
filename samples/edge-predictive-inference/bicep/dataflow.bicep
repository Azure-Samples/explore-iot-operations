param aioInstanceName string
param customLocationName string
param dataClaimName string
param registryEndpointName string
param artifactVersion string
param cameraId string
param modelName string
param topicPrefix string
param scoreThreshold string
param nmsThreshold string
@allowed(['Disabled', 'Enabled'])
param mode string = 'Disabled'

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

resource profile 'Microsoft.IoTOperations/instances/dataflowProfiles@2026-09-03-preview' = {
  parent: aio
  name: 'edge-predictive-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    instanceCount: 1
  }
}

var configuration = [
  { key: 'camera_id', value: cameraId }
  { key: 'model_name', value: modelName }
  { key: 'score_threshold', value: scoreThreshold }
  { key: 'nms_threshold', value: nmsThreshold }
]

resource graph 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflowGraphs@2026-09-03-preview' = {
  parent: profile
  name: 'edge-person-detection'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    mode: mode
    requestDiskPersistence: 'Disabled'
    fileStores: [
      {
        id: 'person-inputs'
        persistentVolumeClaimRef: dataClaimName
        subPath: 'edge-predictive-inference/inputs'
        readOnly: false
      }
      {
        id: 'person-responses'
        persistentVolumeClaimRef: dataClaimName
        subPath: 'edge-predictive-inference/responses'
        readOnly: true
      }
    ]
    nodes: [
      {
        nodeType: 'Source'
        name: 'camera'
        sourceSettings: {
          endpointRef: 'default'
          dataSources: ['${topicPrefix}/frames']
        }
      }
      {
        nodeType: 'Graph'
        name: 'preprocess'
        graphSettings: {
          registryEndpointRef: registryEndpointName
          artifact: 'azure-samples/edge-predictive-inference/preprocess-graph:${artifactVersion}'
          configuration: configuration
        }
      }
      {
        nodeType: 'Graph'
        name: 'inference'
        graphSettings: {
          registryEndpointRef: 'default'
          artifact: 'azureiotoperations/graph-dataflow-inference:0.2.0-preview.0'
          configuration: [
            { key: 'model_name', value: modelName }
            { key: 'read_request_from_disk', value: 'true' }
          ]
        }
      }
      {
        nodeType: 'Graph'
        name: 'postprocess'
        graphSettings: {
          registryEndpointRef: registryEndpointName
          artifact: 'azure-samples/edge-predictive-inference/postprocess-graph:${artifactVersion}'
          configuration: configuration
        }
      }
      {
        nodeType: 'Destination'
        name: 'observations'
        destinationSettings: {
          endpointRef: 'default'
          dataDestination: '${topicPrefix}/\${outputTopic}'
        }
      }
    ]
    nodeConnections: [
      { from: { name: 'camera' }, to: { name: 'preprocess.input' } }
      { from: { name: 'preprocess.output' }, to: { name: 'inference.input' } }
      { from: { name: 'inference.output' }, to: { name: 'postprocess.input' } }
      { from: { name: 'postprocess.output' }, to: { name: 'observations' } }
    ]
  }
}
