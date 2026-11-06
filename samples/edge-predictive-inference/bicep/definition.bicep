param aioInstanceName string
param customLocationName string

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

resource definition 'Microsoft.IoTOperations/instances/aioApplicationDefinitions@2026-09-03-preview' = {
  parent: aio
  name: 'edge-predictive-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    applicationSource: 'UserDefined'
    applicationType: 'AioApplication'
    applicationMetadataRef: 'mcr.microsoft.com/azureiotoperations/inference-connector:0.1.2'
    imageDetails: {
      imageName: 'azureiotoperations/inference-connector'
      registrySettings: {
        registrySettingsType: 'ContainerRegistry'
        containerRegistrySettings: {
          registry: 'mcr.microsoft.com'
        }
      }
      tagDigestSettings: {
        tagDigestType: 'Tag'
        tag: '0.1.2'
      }
    }
    resources: {
      requests: {
        cpu: '100m'
        memory: '128Mi'
      }
    }
  }
}

output applicationDefinitionId string = definition.id
