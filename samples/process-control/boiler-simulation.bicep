metadata description = 'This template deploys CRs that map to the boiler in the OPC simulator.'

/*****************************************************************************/
/*                          Deployment Parameters                            */
/*****************************************************************************/

param customLocationName string
param aioNamespaceName string

/*****************************************************************************/
/*                          Existing AIO instance                             */
/*****************************************************************************/

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource namespace 'Microsoft.DeviceRegistry/namespaces@2025-07-01-preview' existing = {
  name: aioNamespaceName
}

/*****************************************************************************/
/*                                    Asset                                  */
/*****************************************************************************/

var assetName = 'boiler'
var opcUaEndpointName = 'opc-ua-commander-0'

resource device 'Microsoft.DeviceRegistry/namespaces/devices@2025-07-01-preview' = {
  name: 'opc-ua-commander'
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

resource asset 'Microsoft.DeviceRegistry/namespaces/assets@2025-07-01-preview' = {
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
    description: 'Multi-function boiler simulation.'

    enabled: true
    attributes: {
      manufacturer: 'Contoso'
      manufacturerUri: 'http://www.contoso.com/boilers'
      model: 'Oven-003'
      productCode: '12345C'
      hardwareRevision: '2.3'
      softwareRevision: '14.1'
      serialNumber: '12345'
      documentationUri: 'http://docs.contoso.com/boilers/manual'
    }

    datasets: [
      {
        name: 'boiler-simple-write'
        dataPoints: [
          {
            name: 'Boiler #2'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=5017'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'AssetId'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6195'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'DeviceHealth'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6198'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'Manufacturer'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6202'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'ManufacturerUri'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6203'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'BaseTemperature'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6210'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'CurrentTemperature'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6211'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'HeaterState'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6212'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'MaintenanceInterval'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6213'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'OverheatInterval'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6350'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'Overheated'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6214'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'OverheatedThresholdTemperature'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6215'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'TargetTemperature'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6217'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'TemperatureChangeSpeed'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6218'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'ProductCode'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6205'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'ProductInstanceUri'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6206'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'RevisionCounter'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6207'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'SerialNumber'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6208'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
          {
            name: 'SoftwareRevision'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6209'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
       ]
        destinations: [
          {
            target: 'Mqtt'
            configuration: {
              topic: 'azure-iot-operations/data/oven-simple-write'
              retain: 'Never'
              qos: 'Qos1'
            }
          }
        ]
      }
      {
        name: 'boiler-complex-write'
        dataPoints: [
          {
            name: 'BoilerStatus'
            dataSource: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=15013'
            dataPointConfiguration: '{"samplingInterval":500,"queueSize":1}'
          }
        ]
        destinations: [
          {
            target: 'Mqtt'
            configuration: {
              topic: 'azure-iot-operations/data/oven-complex-write'
              retain: 'Never'
              qos: 'Qos1'
            }
          }
        ]
      }

    ]

    managementGroups: [
      {
        name: 'boiler-call'
        actions: [
          {
            name: 'Switch'
            targetUri: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=5017'
            actionType: 'Call'
            typeRef: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=5019'
          }
        ]
      } 
      {
        name: 'boiler-explicit-write'
        actions: [
          {
            name: 'simple-write'
            targetUri: 'nsu=http://microsoft.com/Opc/OpcPlc/Boiler;i=6217'
            actionType: 'Write'
          }
        ]
      } 
    ]
    
    defaultDatasetsConfiguration: '{"publishingInterval":1000,"samplingInterval":500,"queueSize":1}'
    defaultEventsConfiguration: '{"publishingInterval":1000,"samplingInterval":500,"queueSize":1}'
  }
}


