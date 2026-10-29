param aioInstanceName string
param customLocationName string
param dataClaimName string
param registryEndpointName string
param graphs object
param scenarios array
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
  name: 'edge-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    instanceCount: 1
  }
}

resource captures 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflowGraphs@2026-09-03-preview' = [
  for scenario in scenarios: {
    parent: profile
    name: '${scenario.name}-capture'
    extendedLocation: {
      type: 'CustomLocation'
      name: location.id
    }
    properties: {
      mode: mode
      nodes: [
        {
          nodeType: 'Source'
          name: 'trigger'
          sourceSettings: {
            endpointRef: 'default'
            dataSources: ['${scenario.topicPrefix}/trigger']
          }
        }
        {
          nodeType: 'Graph'
          name: 'capture'
          graphSettings: {
            registryEndpointRef: registryEndpointName
            artifact: graphs.capture
            configuration: [
              {
                key: 'action_topic'
                value: 'azure-iot-operations/asset-operations/${scenario.assetName}/control/ExtractClip'
              }
              {
                key: 'stream_configuration_name'
                value: 'camera-snapshots'
              }
              {
                key: 'pre_padding_seconds'
                value: '1'
              }
              {
                key: 'post_padding_seconds'
                value: '0'
              }
              {
                key: 'target'
                value: 'local-shared'
              }
            ]
          }
        }
        {
          nodeType: 'Destination'
          name: 'captured'
          destinationSettings: {
            endpointRef: 'default'
            dataDestination: '${scenario.topicPrefix}/capture'
          }
        }
      ]
      nodeConnections: [
        {
          from: { name: 'trigger' }
          to: { name: 'capture' }
        }
        {
          from: { name: 'capture' }
          to: { name: 'captured' }
        }
      ]
    }
  }
]

resource inference 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflowGraphs@2026-09-03-preview' = [
  for scenario in scenarios: {
    parent: profile
    name: '${scenario.name}-inference'
    extendedLocation: {
      type: 'CustomLocation'
      name: location.id
    }
    properties: {
      mode: mode
      nodes: [
        {
          nodeType: 'Source'
          name: 'capture'
          sourceSettings: {
            endpointRef: 'default'
            dataSources: ['${scenario.topicPrefix}/capture']
          }
        }
        {
          nodeType: 'Graph'
          name: 'preprocessing'
          graphSettings: {
            registryEndpointRef: registryEndpointName
            artifact: graphs.preprocessing
          }
        }
        {
          nodeType: 'Graph'
          name: 'inference'
          graphSettings: {
            registryEndpointRef: registryEndpointName
            artifact: graphs.inference
            configuration: [
              {
                key: 'model_name'
                value: scenario.modelName
              }
              {
                key: 'read_request_from_disk'
                value: 'true'
              }
              {
                key: 'return_input_payload'
                value: 'true'
              }
            ]
          }
        }
        {
          nodeType: 'Destination'
          name: 'inferred'
          destinationSettings: {
            endpointRef: 'default'
            dataDestination: '${scenario.topicPrefix}/inference'
          }
        }
      ]
      nodeConnections: [
        {
          from: { name: 'capture' }
          to: { name: 'preprocessing' }
        }
        {
          from: { name: 'preprocessing' }
          to: { name: 'inference' }
        }
        {
          from: { name: 'inference' }
          to: { name: 'inferred' }
        }
      ]
    }
  }
]

resource postprocessing 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflowGraphs@2026-09-03-preview' = [
  for scenario in scenarios: {
    parent: profile
    name: '${scenario.name}-postprocessing'
    extendedLocation: {
      type: 'CustomLocation'
      name: location.id
    }
    properties: {
      mode: mode
      fileStores: [
        {
          id: 'responses'
          persistentVolumeClaimRef: dataClaimName
          subPath: 'edge-inference/responses'
          readOnly: true
        }
      ]
      nodes: [
        {
          nodeType: 'Source'
          name: 'inferred'
          sourceSettings: {
            endpointRef: 'default'
            dataSources: ['${scenario.topicPrefix}/inference']
          }
        }
        {
          nodeType: 'Graph'
          name: 'postprocessing'
          graphSettings: {
            registryEndpointRef: registryEndpointName
            artifact: graphs.postprocessing
            configuration: [
              {
                key: 'model_name'
                value: scenario.modelName
              }
              {
                key: 'output_tensor_key'
                value: 'detections_0'
              }
              {
                key: 'read_from_disk'
                value: 'true'
              }
              {
                key: 'file_store_id'
                value: 'responses'
              }
              {
                key: 'confidence_threshold'
                value: scenario.confidenceThreshold
              }
            ]
          }
        }
        {
          nodeType: 'Destination'
          name: 'result'
          destinationSettings: {
            endpointRef: 'default'
            dataDestination: '${scenario.topicPrefix}/result'
          }
        }
      ]
      nodeConnections: [
        {
          from: { name: 'inferred' }
          to: { name: 'postprocessing' }
        }
        {
          from: { name: 'postprocessing' }
          to: { name: 'result' }
        }
      ]
    }
  }
]
