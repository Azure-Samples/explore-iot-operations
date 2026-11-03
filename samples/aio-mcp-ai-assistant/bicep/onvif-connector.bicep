param aioInstanceName string
param customLocationName string
param connectorTemplateName string = 'edge-assistant-onvif'
param connectorRegistry string = 'mcr.microsoft.com'
param connectorImageName string = 'azureiotoperations/akri-connectors/onvif'
param connectorImageTag string = '1.5.0'
param connectorImagePullSecretName string = ''

resource customLocation 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

// Preview schemas are validated by ARM when validating and deploying this template.
#disable-next-line BCP081
resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

#disable-next-line BCP081
resource connector 'Microsoft.IoTOperations/instances/akriConnectorTemplates@2026-09-03-preview' = {
  parent: aio
  name: connectorTemplateName
  extendedLocation: {
    name: customLocation.id
    type: 'CustomLocation'
  }
  properties: {
    aioMetadata: {
      aioMinVersion: '1.3.38'
    }
    connectorMetadataRef: 'mcr.microsoft.com/azureiotoperations/akri-connectors/onvif-metadata:1.5.0'
    deviceInboundEndpointTypes: [
      {
        endpointType: 'Microsoft.Onvif'
      }
    ]
    runtimeConfiguration: {
      runtimeConfigurationType: 'ManagedConfiguration'
      managedConfigurationSettings: {
        managedConfigurationType: 'ImageConfiguration'
        imageConfigurationSettings: {
          imageName: connectorImageName
          replicas: 1
          registrySettings: {
            registrySettingsType: 'ContainerRegistry'
            containerRegistrySettings: {
              registry: connectorRegistry
              imagePullSecrets: empty(connectorImagePullSecretName) ? [] : [
                {
                  secretRef: connectorImagePullSecretName
                }
              ]
            }
          }
          tagDigestSettings: {
            tagDigestType: 'Tag'
            tag: connectorImageTag
          }
        }
      }
    }
  }
}

output connectorTemplateId string = connector.id
