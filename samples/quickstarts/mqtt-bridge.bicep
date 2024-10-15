var assetDeltaSchema = '''
{
    "$schema": "Delta/1.0",
    "type": "object",
    "properties": {
        "type": "struct",
        "fields": [
            { "name": "asset_id", "type": "string", "nullable": false, "metadata": {} },
            { "name": "asset_name", "type": "string", "nullable": false, "metadata": {} },
            { "name": "location", "type": "string", "nullable": false, "metadata": {} },
            { "name": "manufacturer", "type": "string", "nullable": false, "metadata": {} },
            { "name": "production_date", "type": "string", "nullable": false, "metadata": {} },
            { "name": "serial_number", "type": "string", "nullable": false, "metadata": {} },
            { "name": "temperature", "type": "double", "nullable": false, "metadata": {} }
        ]
    }
}
'''

param customLocationName string = ''
param defaultDataflowEndpointName string = 'default'
param defaultDataflowProfileName string = 'default'
param schemaRegistryName string = ''
param aioInstanceName string = ''
param eventGridHostName string = ''
param testSchemaName string = 'asset-delta3'

////////////////////////////////////////////////////////////////////////////////
// RESOURCES

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

resource schema 'Microsoft.DeviceRegistry/schemaRegistries/schemas@2024-09-01-preview' = {
  parent: schemaRegistry
  name: testSchemaName
  properties: {
    displayName: 'My Delta Schema'
    description: 'This is a sample delta Schema'
    format: 'Delta/1.0'
    schemaType: 'MessageSchema'
  }
}


resource schemaVersion 'Microsoft.DeviceRegistry/schemaRegistries/schemas/schemaVersions@2024-09-01-preview' = {
  parent: schema
  name: '1'
  properties: {
    description: 'Schema version 1'
    schemaContent: assetDeltaSchema
  }
}

resource MqttBrokerDataflowEndpoint 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-08-15-preview' = {
  parent: aioInstance
  name: 'aiomq'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    endpointType: 'Mqtt'
    mqttSettings: {
      authentication: {
        method: 'ServiceAccountToken'
        serviceAccountTokenSettings: {
          audience: 'aio-internal'
        }
      }
      host: 'aio-broker:18883'
      tls: {
        mode: 'Enabled'
        trustedCaCertificateConfigMapRef: 'azure-iot-operations-aio-ca-trust-bundle  '
      }
    }
  }
}

resource remoteMqttBrokerDataflowEndpoint 'Microsoft.IoTOperations/instances/dataflowEndpoints@2024-08-15-preview' = {
  parent: aioInstance
  name: 'eventgrid'
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    endpointType: 'Mqtt'
    mqttSettings: {
      authentication: {
        method: 'SystemAssignedManagedIdentity'
        systemAssignedManagedIdentitySettings: {}
      }
      host: eventGridHostName
      tls: {
        mode: 'Enabled'
      }
    }
  }
}

resource dataflow_1 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2024-08-15-preview' = {
  parent: defaultDataflowProfile
  name: 'local-to-remote'
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
          endpointRef: MqttBrokerDataflowEndpoint.name
          dataSources: array('tutorial/local')
        }
      }
      {
        operationType: 'Destination'
        destinationSettings: {
          endpointRef: remoteMqttBrokerDataflowEndpoint.name
          dataDestination: 'telemetry/iot-mq'
        }
      }
    ]
  }
} 

resource dataflow_2 'Microsoft.IoTOperations/instances/dataflowProfiles/dataflows@2024-08-15-preview' = {
  parent: defaultDataflowProfile
  name: 'remote-to-local'
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
          endpointRef: remoteMqttBrokerDataflowEndpoint.name
          dataSources: array('telemetry/#')
        }
      }
      {
        operationType: 'Destination'
        destinationSettings: {
          endpointRef: MqttBrokerDataflowEndpoint.name
          dataDestination: 'tutorial/cloud'
        }
      }
    ]
  }
} 
