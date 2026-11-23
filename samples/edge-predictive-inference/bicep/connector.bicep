param aioInstanceName string
param customLocationName string
param dataClaimName string
param modelName string
param modelEndpoint string
param foundryTrustSecret string

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

resource definition 'Microsoft.IoTOperations/instances/aioApplicationDefinitions@2026-09-03-preview' existing = {
  parent: aio
  name: 'edge-predictive-inference'
}

resource configuration 'Microsoft.IoTOperations/instances/aioApplicationDefinitions/aioApplicationConfigurations@2026-09-03-preview' = {
  parent: definition
  name: 'edge-predictive-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    configuration: {
      models: [
        {
          name: modelName
          'inference-provider': 'FoundryLocal'
          'http-endpoint': modelEndpoint
          'fl-client-max-retries': 1
          auth: {
            sat: {}
          }
          'trust-bundle': {
            'trust-settings-key': 'ca.crt'
          }
          mrpc: {
            'worker-count': 1
          }
          'data-volume': {
            'mount-path': '/data'
            'read-sub-path': 'edge-predictive-inference/inputs'
            'write-sub-path': 'edge-predictive-inference/responses'
          }
          'write-response-to-disk': true
        }
      ]
    }
    runtimeConfiguration: {
      runtimeConfigurationType: 'ImageConfiguration'
      imageConfigurationSettings: {
        replicas: 1
        imagePullPolicy: 'IfNotPresent'
        persistentVolumeClaims: [
          {
            claimName: dataClaimName
            mountPath: '/data'
          }
        ]
        trustSettings: {
          trustListSecretRef: foundryTrustSecret
        }
      }
    }
  }
}
