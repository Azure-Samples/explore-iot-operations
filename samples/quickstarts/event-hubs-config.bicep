@description('Location for cloud resources')
param mqExtensionName string = 'mq'
param clusterName string = 'clusterName'
param eventHubNamespaceName string = 'default'

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2021-10-01' existing = {
  name: clusterName
}

resource mqExtension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' existing = {
  name: mqExtensionName
  scope: connectedCluster
}

resource ehNamespace 'Microsoft.EventHub/namespaces@2021-11-01' existing = {
  name: eventHubNamespaceName
}

// Role assignment for Event Hubs Data Receiver role
resource roleAssignmentDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNamespace.id, mqExtension.id, '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: ehNamespace
  properties: {
     // ID for Event Hubs Data Receiver role is a638d3c7-ab3a-418d-83e6-5f17a39d4fde
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde') 
    principalId: mqExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role assignment for Event Hubs Data Sender role
resource roleAssignmentDataSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNamespace.id, mqExtension.id, '69b88ce2-a752-421f-bd8b-e230189e1d63')
  scope: ehNamespace
  properties: {
    // ID for Event Hubs Data Sender role is 2b629674-e913-4c01-ae53-ef4638d8f975
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '2b629674-e913-4c01-ae53-ef4638d8f975') 
    principalId: mqExtension.identity.principalId
    principalType: 'ServicePrincipal'
  }
}