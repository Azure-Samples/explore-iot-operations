var opcuaSchemaContent = '''
{
  "$schema": "Delta/1.0",
  "type": "object",
  "properties": {
    "type": "struct",
    "fields": [
      {
        "name": "temperature",
        "type": {
          "type": "struct",
          "fields": [
            {
              "name": "SourceTimestamp",
              "type": "string",
              "nullable": true,
              "metadata": {}
            },
            {
              "name": "Value",
              "type": "integer",
              "nullable": true,
              "metadata": {}
            },
            {
              "name": "StatusCode",
              "type": {
                "type": "struct",
                "fields": [
                  {
                    "name": "Code",
                    "type": "integer",
                    "nullable": true,
                    "metadata": {}
                  },
                  {
                    "name": "Symbol",
                    "type": "string",
                    "nullable": true,
                    "metadata": {}
                  }
                ]
              },
              "nullable": true,
              "metadata": {}
            }
          ]
        },
        "nullable": true,
        "metadata": {}
      },
      {
        "name": "Tag 10",
        "type": {
          "type": "struct",
          "fields": [
            {
              "name": "SourceTimestamp",
              "type": "string",
              "nullable": true,
              "metadata": {}
            },
            {
              "name": "Value",
              "type": "integer",
              "nullable": true,
              "metadata": {}
            },
            {
              "name": "StatusCode",
              "type": {
                "type": "struct",
                "fields": [
                  {
                    "name": "Code",
                    "type": "integer",
                    "nullable": true,
                    "metadata": {}
                  },
                  {
                    "name": "Symbol",
                    "type": "string",
                    "nullable": true,
                    "metadata": {}
                  }
                ]
              },
              "nullable": true,
              "metadata": {}
            }
          ]
        },
        "nullable": true,
        "metadata": {}
      }
    ]
  }
}
'''


param customLocationName string = '<CUSTOM_LOCATION_NAME>'
param defaultDataflowEndpointName string = 'default'
param defaultDataflowProfileName string = 'default'
param schemaRegistryName string = '<SCHEMA_REGISTRY_NAME>'
param aioInstanceName string = '<AIO_INSTANCE_NAME>'
param hostName string = '<HOST>.servicebus.windows.net:9093'

param opcuaSchemaName string = 'opcua-output-delta'
param opcuaSchemaVer string = '1'

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aioInstance 'Microsoft.IoTOperations/instances@2024-08-15-preview' existing = {
  name: aioInstanceName
}

resource defaultDataflowEndpoint 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-08-15-preview' existing = {
  parent: aioInstance
  name: defaultDataflowEndpointName
}

resource defaultDataflowProfile 'Microsoft.IoTOperations/instances/dataflowProfiles@2024-08-15-preview' existing = {
  parent: aioInstance
  name: defaultDataflowProfileName
}

resource schemaRegistry 'Microsoft.DeviceRegistry/schemaRegistries@2024-09-01-preview' existing = {
  name: schemaRegistryName
}

resource opcSchema 'Microsoft.DeviceRegistry/schemaRegistries/schemas@2024-09-01-preview' = {
  parent: schemaRegistry
  name: opcuaSchemaName
  properties: {
    displayName: 'OPC UA Delta Schema'
    description: 'This is a OPC UA delta Schema'
    format: 'Delta/1.0'
    schemaType: 'MessageSchema'
  }
}

resource opcuaSchemaInstance 'Microsoft.DeviceRegistry/schemaRegistries/schemas/schemaVersions@2024-09-01-preview' = {
  parent: opcSchema
  name: opcuaSchemaVer
  properties: {
    description: 'Schema version'
    schemaContent: opcuaSchemaContent
  }
}

// EventHub Endpoint
resource kafkaEndpoint 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-08-15-preview' = {
  parent: aioInstance
  name: 'eventhubs'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    endpointType: 'Kafka'
    kafkaSettings: {
      host: hostName
      authentication: {
        method: 'SystemAssignedManagedIdentity'
        systemAssignedManagedIdentitySettings: {}
      }
      tls: {
        mode: 'Enabled'
      }
      batching: {
        enabled: true
        latencyMs: 1000
        maxMessages: 100
        maxBytes: 1024
      }
      kafkaAcks: 'All'
      copyMqttProperties: 'Enabled'
      consumerGroupId: 'mqConnector'
    }
  }
}

// Kafka Dataflow
resource kafka_dataflow 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2024-08-15-preview' = {
  parent: defaultDataflowProfile
  name: 'local-to-eventhub'
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
          dataSources: array('azure-iot-operations/data/thermostat')
        }
      }
      {
        operationType: 'Destination'
        destinationSettings: {
          endpointRef: kafkaEndpoint.name
          dataDestination: 'temperature'
        }
      }
    ]
  }
} 
