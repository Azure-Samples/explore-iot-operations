
param location string = any(resourceGroup().location)
param mqInstanceName string
param customLocationName string
param fabricEndpointUrl string
param fabricWorkspaceName string
param fabricLakehouseName string

var repo = 'mcr.microsoft.com/azureiotoperations'
var imageTag = '0.1.0-preview'

resource mq 'Microsoft.IoTOperationsMQ/mq@2023-10-04-preview' existing = {
  name: mqInstanceName
}

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

// Datalake connector - Fabric
resource datalakeConnectorFabric 'Microsoft.IoTOperationsMQ/mq/dataLakeConnector@2023-10-04-preview' = {
  parent: mq
  name: 'dl-conntr-fabric'
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    image: {
      pullPolicy: 'Always'
      repository: '${repo}/datalake'
      tag: imageTag
    }
    logLevel: 'debug'
    databaseFormat: 'delta'
    protocol: 'v5'
    target: {
      fabricOneLake: {
        authentication: {
          systemAssignedManagedIdentity: {
            audience: 'https://storage.azure.com/'
          }
        }
        fabricPath: 'tables'
        endpoint: fabricEndpointUrl
        names: {
          workspaceName: fabricWorkspaceName
          lakehouseName: fabricLakehouseName
        }
      }
    }
  }
}

resource dlcTopicmapFabric 'Microsoft.IoTOperationsMQ/mq/dataLakeConnector/topicMap@2023-10-04-preview' = {
  parent: datalakeConnectorFabric
  name: 'dlc-topicmap-fabric'
  location: location
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    dataLakeConnectorRef: datalakeConnectorFabric.name
    mapping: {
      allowedLatencySecs: 30
      clientId: 'dlc2'
      maxMessagesPerBatch: 200
      messagePayloadType: 'json'
      qos: 1
      mqttSourceTopic: 'sensor/data'
      table: {
        tableName: 'sensorReadings'
        schema: [
          {
            name: 'timestamp'
            format: 'timestamp'
            optional: false
            mapping: '$received_time'
          }
          {
            name: 'mqttTopic'
            format: 'utf8'
            optional: false
            mapping: '$topic'
          }
          {
            name: 'sensor_id'
            format: 'utf8'
            optional: false
            mapping: 'sensor_id'
          }
          {
            name: 'temperature'
            format: 'float32'
            optional: false
            mapping: 'temperature'
          }
          {
            name: 'pressure'
            format: 'float32'
            optional: false
            mapping: 'pressure'
          }
          {
            name: 'vibration'
            format: 'float32'
            optional: false
            mapping: 'vibration'
          }
        ]
      }
    }
  }
}
