metadata description = 'This template deploys components that are required to show data flowing after cluster provisioning and AIO deployment.'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/

param clusterName string
param customLocationName string
param aioExtensionName string
param aioInstanceName string
param aioNamespaceName string
param resourceSuffix string = substring(uniqueString(subscription().id, resourceGroup().id, clusterName), 0, 10)
param eventHubName string = 'aio-eh-${resourceSuffix}'
param defaultDataflowEndpointName string = 'default'
param defaultDataflowProfileName string = 'default'
param createRoleAssignment bool = true

/*****************************************************************************/
/*                          Existing AIO cluster                             */
/*****************************************************************************/

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2021-10-01' existing = {
  name: clusterName
}

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aioExtension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' existing = {
  name: aioExtensionName
  scope: connectedCluster
}

resource aioInstance 'Microsoft.IoTOperations/instances@2025-04-01' existing = {
  name: aioInstanceName
}

resource defaultDataflowEndpoint 'Microsoft.IoTOperations/instances/dataflowEndpoints@2025-04-01' existing = {
  name: defaultDataflowEndpointName
}

resource defaultDataflowProfile 'Microsoft.IoTOperations/instances/dataflowProfiles@2025-04-01' existing = {
  name: defaultDataflowProfileName
  parent: aioInstance
}

resource namespace 'Microsoft.DeviceRegistry/namespaces@2025-10-01' existing = {
  name: aioNamespaceName
}

/*****************************************************************************/
/*                                    Asset                                  */
/*****************************************************************************/

var assetName = 'oven'
var opcUaEndpointName = 'opc-ua-connector-0'
var deviceName = 'opc-ua-connector'

resource device 'Microsoft.DeviceRegistry/namespaces/devices@2025-10-01' = {
  name: deviceName
  parent: namespace
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocation.id
  }
  properties: {
    endpoints: {
      outbound: {
        assigned: {}
      }
      inbound: {
        '${opcUaEndpointName}': {
          endpointType: 'Microsoft.OpcUa'
          address: 'opc.tcp://opcplc-000000:50000'
          authentication: {
            method: 'Anonymous'
          }
        }
      }
    }
  }
}

resource asset 'Microsoft.DeviceRegistry/namespaces/assets@2025-10-01' = {
  name: assetName
  parent: namespace
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocation.id
  }
  properties: {
    displayName: assetName
    deviceRef: {
      deviceName: device.name
      endpointName: opcUaEndpointName
    }
    description: 'Multi-function large oven for baked goods.'

    enabled: true
    attributes: {
      manufacturer: 'Contoso'
      manufacturerUri: 'http://www.contoso.com/ovens'
      model: 'Oven-003'
      productCode: '12345C'
      hardwareRevision: '2.3'
      softwareRevision: '14.1'
      serialNumber: '12345'
      documentationUri: 'http://docs.contoso.com/ovens'
    }

    datasets: [
      {
        name: 'Oven telemetry'
        dataPoints: [
          {
            name: 'Temperature'
            dataSource: 'ns=3;s=SpikeData'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'EnergyUse'
            dataSource: 'ns=3;s=FastUInt10'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'Weight'
            dataSource: 'ns=3;s=FastUInt9'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
        ]
        destinations: [
          {
            target: 'Mqtt'
            configuration: {
              topic: 'azure-iot-operations/data/oven'
              retain: 'Never'
              qos: 'Qos1'
            }
          }
        ]
      }
    ]

    defaultDatasetsConfiguration: '{"publishingInterval":1000,"samplingInterval":500,"queueSize":1}'
    defaultEventsConfiguration: '{"publishingInterval":1000,"samplingInterval":500,"queueSize":1}'
  }
}

/*****************************************************************************/
/*                                  Event Hub                                */
/*****************************************************************************/

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubName
  location: resourceGroup().location
  properties: {
    disableLocalAuth: false
  }
}

// Role assignment for Event Hubs Data Sender role
resource roleAssignmentDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createRoleAssignment) {
  name: guid(eventHubNamespace.id, aioExtension.id, '69b88ce2-a752-421f-bd8b-e230189e1d63')
  scope: eventHubNamespace
  properties: {
    // ID for Event Hubs Data Sender role is 2b629674-e913-4c01-ae53-ef4638d8f975
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '2b629674-e913-4c01-ae53-ef4638d8f975')
    principalId: aioExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  name: 'destinationeh'
  parent: eventHubNamespace
  properties: {
    messageRetentionInDays: 1
    partitionCount: 1
  }
}

/*****************************************************************************/
/*                                    Data flow                              */
/*****************************************************************************/

resource dataflowEndpointEventHub 'Microsoft.IoTOperations/instances/dataflowEndpoints@2025-04-01' = {
  parent: aioInstance
  name: 'quickstart-eh-endpoint'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    endpointType: 'Kafka'
    kafkaSettings: {
      host: '${eventHubName}.servicebus.windows.net:9093'
      batching: {
        latencyMs: 0
        maxMessages: 100
      }
      tls: {
        mode: 'Enabled'
      }
      authentication: {
        method: 'SystemAssignedManagedIdentity'
        systemAssignedManagedIdentitySettings: {
          audience: 'https://${eventHubName}.servicebus.windows.net'
        }
      }
    }
  }
  dependsOn: [
    eventHubNamespace
  ]
}

resource dataflowCToF 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2025-04-01' = {
  parent: defaultDataflowProfile
  name: 'quickstart-oven-data-flow'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    mode: 'Enabled'
    operations: [
      {
        operationType: 'Source'
        sourceSettings: {
          endpointRef: defaultDataflowEndpoint.name
          assetRef: asset.name
          serializationFormat: 'Json'
          dataSources: ['azure-iot-operations/data/${asset.name}']
        }
      }
      {
        operationType: 'BuiltInTransformation'
        builtInTransformationSettings: {
          serializationFormat: 'Json'
          map: [
            {
              type: 'PassThrough'
              inputs: [
                '*'
              ]
              output: '*'
            }
            {
              type: 'Compute'
              description: 'Temperature in F'
              inputs: [
                'Temperature.Value ? $last'
              ]
              expression: '$1 * 9/5 + 32'
              output: 'TemperatureF'
            }
            {
              type: 'Compute'
              description: 'Weight Offset'
              inputs: [
                'Weight.Value ? $last'
              ]
              expression: '$1 - 150'
              output: 'FillWeight'
            }
            {
              type: 'Compute'
              inputs: [
                'Temperature.Value ? $last'
              ]
              expression: '$1 > 225'
              output: 'Spike'
            }
            {
              inputs: [
                '$metadata.user_property.externalAssetId'
              ]
              output: 'AssetId'
            }
          ]
        }
      }
      {
        operationType: 'Destination'
        destinationSettings: {
          endpointRef: dataflowEndpointEventHub.name
          dataDestination: 'destinationeh'
        }
      }
    ]
  }
  dependsOn: [
    eventHub
  ]
}

output eventHub object = {
  name: eventHub.name
  namespace: eventHubNamespace.name
}
