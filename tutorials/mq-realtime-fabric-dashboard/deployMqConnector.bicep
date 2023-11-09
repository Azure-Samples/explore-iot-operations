
metadata description = 'This template deploys MQ Kafka Connector, Event Hubs, and configures role assignments'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/


param location string = any(resourceGroup().location)

param customLocationName string = '${any(resourceGroup().name)}-cl'
param mqInstanceName string = 'mq-instance'
param clusterName string = 'iot-operations-cluster'
param mqExtensionName string = 'mq'

/*****************************************************************************/
/*                                Constants                                  */
/*****************************************************************************/

var repo = 'mcr.microsoft.com/azureiotoperations'
var imageTag = '0.1.0-preview'



/*****************************************************************************/
/*                           Existing resources.                             */
/*****************************************************************************/

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource mq 'Microsoft.IoTOperationsMQ/mq@2023-10-04-preview' existing = {
  name: mqInstanceName
}

resource cluster 'Microsoft.Kubernetes/connectedClusters@2021-03-01' existing = {
  name: clusterName
}

resource mqExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' existing = {
  scope: cluster
  name: mqExtensionName
}


/*****************************************************************************/
/*                          Cloud resources                                  */
/*****************************************************************************/

var eventHubSku = 'Standard'


resource eventHubNamespace 'Microsoft.EventHub/namespaces@2021-11-01' = {
  name: 'ehns-${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: eventHubSku
    tier: eventHubSku
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: false
    maximumThroughputUnits: 0
  }
}

resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2017-04-01' = {
  parent: eventHubNamespace
  name: 'eh-eventstream'
  properties: {
    messageRetentionInDays: 7
    partitionCount: 1
  }
}

resource eventHubCg 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2017-04-01' = {
  parent: eventHub
  name: 'eventHubConsumerGroup'
  properties: {}
}


/*****************************************************************************/
/*                           MQ resources.                                   */
/*****************************************************************************/

var mqttTopic = 'sensor/data'

resource kafkaConnector 'Microsoft.IoTOperationsMQ/mq/kafkaConnector@2023-10-04-preview' = {
  parent: mq
  name: 'kafka-conntr'
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    image: {
      pullPolicy: 'Always'
      repository: '${repo}/kafka'
      tag: imageTag
    }
    instances: 1
    kafkaConnection: {
      endpoint: '${eventHubNamespace.name}.servicebus.windows.net:9093'
      tls: {
        tlsEnabled: true
      }
      authentication: {
        enabled: true
        authType: {
          systemAssignedManagedIdentity: {
            audience: 'https://${eventHubNamespace.name}.servicebus.windows.net'
          }
        }
      }
    }
    localBrokerConnection: {
      endpoint: 'aio-mq-dmqtt-frontend:8883'
      authentication: {
        kubernetes: {}
      }
      tls: {
        tlsEnabled: true
        trustedCaCertificateConfigMap: 'aio-ca-trust-bundle-test-only'
      }
    }
  }
  dependsOn: [
    eventHubNamespace
  ]
}

resource kcTopicmap 'Microsoft.IoTOperationsMQ/mq/kafkaConnector/topicMap@2023-10-04-preview' = {
  parent: kafkaConnector
  name: 'kc-topicmap'
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    kafkaConnectorRef: kafkaConnector.name
    compression: 'none'
    batching: {
      enabled: false
    }
    routes: [
      {
        mqttToKafka: {
          kafkaTopic: eventHub.name
          mqttTopic: mqttTopic
          name: 'dataTopic'
          kafkaAcks: 'one'
        }
      }
    ]
  }
}


/*****************************************************************************/
/*                          Role assignments                                 */
/*****************************************************************************/

// Role assignment for Event Hub Data Receiver role
resource roleAssignmentDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, mqExtension.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: eventHubNamespace
  properties: {
     // ID for Event Hub Data Receiver role is a638d3c7-ab3a-418d-83e6-5f17a39d4fde
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde') 
    principalId: mqExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role assignment for Event Hub Data Sender role
resource roleAssignmentDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, mqExtension.id, '69b88ce2-a752-421f-bd8b-e230189e1d63')
  scope: eventHubNamespace
  properties: {
    // ID for Event Hub Data Sender role is 2b629674-e913-4c01-ae53-ef4638d8f975
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '2b629674-e913-4c01-ae53-ef4638d8f975') 
    principalId: mqExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

