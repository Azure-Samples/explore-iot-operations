
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

param mqFrontendServer string = 'mq-dmqtt-frontend'

param mqListenerName string = 'listener'

param mqBrokerName string = 'broker'

param mqAuthnName string = 'authn'

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
param mqMemoryProfile string = 'medium'


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


var MQ_PROPERTIES = {
  domain: 'aio-mq-dmqtt-frontend.${AIO_CLUSTER_RELEASE_NAMESPACE}'
  port: 1883
  localUrl: 'mqtts://aio-mq-dmqtt-frontend.${AIO_CLUSTER_RELEASE_NAMESPACE}:1883'
  name: 'aio-mq-dmqtt-frontend'
  satAudience: 'aio-mq'
}

var repo = 'mcr.microsoft.com/azureiotoperations'

var __VERSION__ = '0.2.0-preview'
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
/*                     MQ resources.                                         */
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
    diskBackedMessageBufferSettings: {
      maxSize: '2Gi'
    }
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

/*****************************************************************************/
/*                        Outputs.                                           */
/*****************************************************************************/

output mqExtensionName string = mqExtension.name
output customLocationName string = customLocationName
output mqInstanceName string = mqInstanceName
