metadata description = 'This template deploys components that are required to show data flowing after cluster provisioning and AIO deployment.'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/

param clusterName string
param customLocationName string
param aioExtensionName string
param aioInstanceName string
param resourceSuffix string = substring(uniqueString(subscription().id, resourceGroup().id, clusterName), 0, 10)
param eventHubName string = 'aio-eh-${resourceSuffix}'

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

resource aioInstance 'Microsoft.IoTOperations/instances@2024-09-15-preview' existing = {
  name: aioInstanceName
}

/*****************************************************************************/
/*                                    Asset                                  */
/*****************************************************************************/

var assetName = 'oven'

resource assetEndpoint 'Microsoft.DeviceRegistry/assetEndpointProfiles@2024-09-01-preview' = {
  name: 'opc-ua-connector-0'
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocation.id
  }
  properties: {
    targetAddress: 'opc.tcp://opcplc-000000:50000'
    endpointProfileType: ''
    authentication: {
      method: 'Anonymous'
    }
  }
}

resource asset 'Microsoft.DeviceRegistry/assets@2024-09-01-preview' = {
  name: assetName
  location: resourceGroup().location
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocation.id
  }
  properties: {
    displayName: assetName
    assetEndpointProfileRef: assetEndpoint.name
    description: 'an oven is essential for baking a wide variety of products'

    enabled: true
    externalAssetId: '32faab3f-88e8-4f38-b901-e175dde50c28'
    manufacturer: 'http://asset.oven.contoso'
    manufacturerUri: 'http://oven.asset.contoso'
    model: 'Mymodel'
    productCode: '12345C'
    hardwareRevision: 'http://docs.oven.asset.contoso'
    softwareRevision: '1.1'
    serialNumber: '12345'
    documentationUri: 'http://docs.oven.asset.contoso'

    datasets: [
      {
        name: 'some randome datasets name'
        dataPoints: [
          {
            name: 'Temperature'
            dataSource: 'ns=3;s=FastUInt100'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
            observabilityMode: 'None'
          }
          {
            name: 'FillWeight'
            dataSource: 'ns=3;s=FastUInt1004'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
            observabilityMode: 'None'
          }
          {
            name: 'EnergyUse'
            dataSource: 'ns=3;s=FastUInt1005'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
            observabilityMode: 'None'
          }
        ]
      }
    ]

    defaultDatasetsConfiguration: '{"publishingInterval":1000,"samplingInterval":500,"queueSize":1}'
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
resource roleAssignmentDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
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
/*                                    Dataflow                               */
/*****************************************************************************/

resource dataflowEndpointMqttSource 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-09-15-preview' = {
  parent: aioInstance
  name: 'quickstart-mqtt-endpoint'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    endpointType: 'Mqtt'
    mqttSettings: {
      host: 'aio-broker:18883'
      tls: {
        mode: 'Enabled'
        trustedCaCertificateConfigMapRef: 'azure-iot-operations-aio-ca-trust-bundle'
      }
      authentication: {
        method: 'ServiceAccountToken'
        serviceAccountTokenSettings: {
          audience: 'aio-internal'
        }
      }
    }
  }
}

resource dataflowEndpointEventHub 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-09-15-preview' = {
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

resource dataflowProfile 'Microsoft.IoTOperations/instances/dataflowProfiles@2024-09-15-preview' = {
  parent: aioInstance
  name: 'quickstart-profile'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    diagnostics: {
      logs: {
        level: 'debug'
      }
    }
    instanceCount: 1
  }
  dependsOn: [
    eventHub
  ]
}

resource dataflowCToF 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2024-09-15-preview' = {
  parent: dataflowProfile
  name: 'quickstart-oven-dataflow'
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
          endpointRef: dataflowEndpointMqttSource.name
          assetRef: asset.name
          serializationFormat: 'Json'
          dataSources: ['azure-iot-operations/data/${assetName}']
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
              inputs: [
                'Temperature.Value ? $last'
              ]
              expression: '$1 > 225'
              output: 'Spike'
            }
            {
              type: 'Rename'
              inputs: [
                'FillWeight.Value'
              ]
              output: 'FillWeight'
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

output eventHubName string = eventHubNamespace.name
