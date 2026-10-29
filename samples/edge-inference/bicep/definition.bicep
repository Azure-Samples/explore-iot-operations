param aioInstanceName string
param customLocationName string
param image object

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

resource definition 'Microsoft.IoTOperations/instances/aioApplicationDefinitions@2026-09-03-preview' = {
  parent: aio
  name: 'edge-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    applicationSource: 'UserDefined'
    applicationType: 'AioApplication'
    applicationMetadataRef: '${image.registry}/${image.name}:${image.tag}'
    imageDetails: {
      imageName: image.name
      registrySettings: {
        registrySettingsType: 'ContainerRegistry'
        containerRegistrySettings: {
          registry: image.registry
        }
      }
      tagDigestSettings: {
        tagDigestType: 'Tag'
        tag: image.tag
      }
    }
    resources: {
      requests: {
        cpu: '250m'
        memory: '256Mi'
      }
    }
  }
}

output definitionId string = definition.id
