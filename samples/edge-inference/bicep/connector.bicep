param aioInstanceName string
param customLocationName string
param dataClaimName string
param foundryNamespace string
param trustBundleName string
param scenarios array

resource location 'Microsoft.ExtendedLocation/customLocations@2021-08-31-preview' existing = {
  name: customLocationName
}

resource aio 'Microsoft.IoTOperations/instances@2026-09-03-preview' existing = {
  name: aioInstanceName
}

resource definition 'Microsoft.IoTOperations/instances/aioApplicationDefinitions@2026-09-03-preview' existing = {
  parent: aio
  name: 'edge-inference'
}

resource configuration 'Microsoft.IoTOperations/instances/aioApplicationDefinitions/aioApplicationConfigurations@2026-09-03-preview' = {
  parent: definition
  name: 'edge-inference'
  extendedLocation: {
    type: 'CustomLocation'
    name: location.id
  }
  properties: {
    configuration: {
      models: [
        for scenario in scenarios: {
          name: scenario.modelName
          'inference-provider': 'FoundryLocal'
          'http-endpoint': 'https://${scenario.modelName}.${foundryNamespace}.svc.cluster.local:5000'
          'fl-client-max-retries': 3
          auth: {
            sat: {}
          }
          'trust-bundle': {
            'trust-settings-key': 'ca.crt'
          }
          mrpc: {
            'worker-count': 2
          }
          'data-volume': {
            'mount-path': '/data'
            'read-sub-path': 'edge-inference/media/recordings'
            'write-sub-path': 'edge-inference/responses'
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
          trustListSecretRef: trustBundleName
        }
      }
    }
  }
}
