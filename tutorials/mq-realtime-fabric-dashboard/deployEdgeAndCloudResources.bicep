
metadata description = 'This template deploys IoT Operations components, Event Hubs and sets RBAC'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/

param clusterName string

@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus2'
  'westus3'
  'westeurope'
  'northeurope'
  'eastus2euap'
])
param clusterLocation string = location

@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus2'
  'westus3'
  'westeurope'
  'northeurope'
  'eastus2euap'
])
param location string = any(resourceGroup().location)

//param customLocationName string = '${clusterName}-cl'
param customLocationName string = '${any(resourceGroup().name)}-cl'



param mqInstanceName string = 'mq-instance'

param mqListenerName string = 'listener'

param mqBrokerName string = 'broker'

param mqFrontendReplicas int = 1

param mqFrontendWorkers int = 1

param mqBackendRedundancyFactor int = 1

param mqBackendWorkers int = 1

param mqBackendPartitions int = 1

@allowed([
  'auto'
  'distributed'
])
param mqMode string = 'distributed'

@allowed([
  'tiny'
  'low'
  'medium'
  'high'
])
param mqMemoryProfile string = 'tiny'


@allowed([
  'clusterIp'
  'loadBalancer'
  'nodePort'
])
param mqServiceType string = 'clusterIp'


/*****************************************************************************/
/*                                Constants                                  */
/*****************************************************************************/

var AIO_CLUSTER_RELEASE_NAMESPACE = 'azure-iot-operations'

var AIO_EXTENSION_SCOPE = {
  cluster: {
    releaseNamespace: AIO_CLUSTER_RELEASE_NAMESPACE
  }
}


var repo = 'mcr.microsoft.com/azureiotoperations'

var __VERSION__ = '0.4.0-preview'
var __TRAIN__ = 'preview'


/*****************************************************************************/
/*         Existing Arc-enabled cluster where AIO will be deployed.          */
/*****************************************************************************/

resource cluster 'Microsoft.Kubernetes/connectedClusters@2021-03-01' existing = {
  name: clusterName
}

/*****************************************************************************/
/*                        MQ Extension                                       */
/*****************************************************************************/




resource mqExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' = {
  scope: cluster
  name: 'mq-${any(resourceGroup().name)}'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.iotoperations.mq'
    version: __VERSION__
    releaseTrain: __TRAIN__
    autoUpgradeMinorVersion: false
    scope: AIO_EXTENSION_SCOPE
  }

}

/*
resource mqExtension 'Microsoft.KubernetesConfiguration/extensions@2022-03-01' existing = {
  scope: cluster
  name: 'mq-${resourceGroup().name}'
}
*/

/*****************************************************************************/
/*            Azure Arc custom location and resource sync rules.             */
/*****************************************************************************/


resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' = {
  name: customLocationName
  location: clusterLocation
  properties: {
    hostResourceId: cluster.id
    namespace: AIO_CLUSTER_RELEASE_NAMESPACE
    displayName: customLocationName
    clusterExtensionIds: [
      mqExtension.id
    ]
  }
}

/*
resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
    name: customLocationName
}
*/

resource mq_syncRule 'Microsoft.ExtendedLocation/customLocations/resourceSyncRules@2021-08-31-preview' = {
  parent: customLocation
  name: '${customLocationName}-mq-sync'
  location: clusterLocation
  properties: {
    priority: 400
    selector: {
      matchLabels: {
        #disable-next-line no-hardcoded-env-urls
        'management.azure.com/provider-name': 'microsoft.iotoperationsmq'
      }
    }
    targetResourceGroup: resourceGroup().id
  }
}

/*****************************************************************************/
/*     MQ resources.                                                         */
/*****************************************************************************/


resource mq 'Microsoft.IoTOperationsMQ/mq@2023-10-04-preview' = {
  name: mqInstanceName
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {}
}

resource broker 'Microsoft.IoTOperationsMQ/mq/broker@2023-10-04-preview' = {
  parent: mq
  name: mqBrokerName
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    authImage: {
      pullPolicy: 'Always'
      repository: '${repo}/dmqtt-authentication'
      tag: __VERSION__
    }
    brokerImage: {
      pullPolicy: 'Always'
      repository: '${repo}/dmqtt-pod'
      tag: __VERSION__
    }
    healthManagerImage: {
      pullPolicy: 'Always'
      repository: '${repo}/dmqtt-operator'
      tag: __VERSION__
    }
    diagnostics: {
      probeImage: '${repo}/diagnostics-probe:${__VERSION__}'
      enableSelfCheck: true
    }
    mode: mqMode
    encryptInternalTraffic: false
    memoryProfile: mqMemoryProfile
    cardinality: {
      backendChain: {
        partitions: mqBackendPartitions
        workers: mqBackendWorkers
        redundancyFactor: mqBackendRedundancyFactor
      }
      frontend: {
        replicas: mqFrontendReplicas
        workers: mqFrontendWorkers
      }
    }
  }
}

resource brokerDiagnostics 'Microsoft.IoTOperationsMQ/mq/diagnosticService@2023-10-04-preview' = {
  parent: mq
  name: 'diagnostics'
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    image: {
      repository: '${repo}/diagnostics-service'
      tag: __VERSION__
    }
    logLevel: 'info'
    logFormat: 'text'
  }
}

resource nonTlsListener 'Microsoft.IoTOperationsMQ/mq/broker/listener@2023-10-04-preview' = {
  parent: broker
  name: mqListenerName
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    serviceType: mqServiceType
    authenticationEnabled: false
    authorizationEnabled: false
    brokerRef: broker.name
    port: 1883
  }
}

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
      tag: __VERSION__
    }
    instances: 2
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
  }
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
          kafkaTopic: eventHubOne.name
          mqttTopic: '#'
          name: 'dataTopic'
          kafkaAcks: 'one'
          sharedSubscription: {
            groupName: 'group1'
            groupMinimumShareNumber: 2
          }
        }
      }
    ]
  }
}

/*****************************************************************************/
/*                          Cloud resources                                  */
/*****************************************************************************/

param eventHubSku string = 'Standard'


resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
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
    minimumTlsVersion: '1.2'
  }
}

resource eventHubOne 'Microsoft.EventHub/namespaces/eventhubs@2017-04-01' = {
  parent: eventHubNamespace
  name: 'eh-${uniqueString(resourceGroup().id)}-1'
  properties: {
    messageRetentionInDays: 7
    partitionCount: 1
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
