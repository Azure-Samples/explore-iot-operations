metadata description = 'This template deploys components that are required to verify that the custom HTTP/REST connector created in the docs walkthrough is working as expected. Specific components are Event Hubs namespace an data flow'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/

param clusterName string
param customLocationName string
param aioExtensionName string
param aioInstanceName string
param aioAssetName string
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

/*****************************************************************************/
/*                                  Event Hub                                */
/*****************************************************************************/

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
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
  name: 'thermostateh'
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
  name: 'thermostat-eh-endpoint'
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

resource dataflowThermostat 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2025-04-01' = {
  parent: defaultDataflowProfile
  name: 'thermostat-data-flow'
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
          assetRef: aioAssetName
          serializationFormat: 'Json'
          dataSources: ['machine/thermostat1/status']
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
          ]
        }
      }
      {
        operationType: 'Destination'
        destinationSettings: {
          endpointRef: dataflowEndpointEventHub.name
          dataDestination: 'thermostateh'
        }
      }
    ]
  }
  dependsOn: [
    eventHub
  ]
}

output eventHub object = {
  namespace: eventHubNamespace.name
  name: eventHub.name
}
