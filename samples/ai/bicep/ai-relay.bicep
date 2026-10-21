@description('Authentication used by the relay pod to listen on the Hybrid Connection.')
@allowed([
  'SharedAccessSignature'
  'SystemAssignedManagedIdentity'
])
param authMode string = 'SystemAssignedManagedIdentity'

@description('Existing Arc-connected cluster in this resource group. Required for managed identity.')
param clusterName string = ''

@description('Existing AIO Arc extension whose identity receives Azure Relay Listener access.')
param aioExtensionName string = ''

param location string = resourceGroup().location

@allowed([
  'mcp'
  'a2a'
  'both'
])
param endpointMode string = 'mcp'

param relayNamespaceName string
param hybridConnectionName string
param apimName string
param apimPublisherEmail string
param apimPublisherName string

@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
  'BasicV2'
  'StandardV2'
])
param apimSku string = 'BasicV2'

@minValue(1)
param apimCapacity int = 1

@description('Entra app client ID used as the inbound APIM audience.')
param entraAppId string

@description('Tenant that owns the app and issues the caller tokens.')
param entraTenantId string

@description('Delegated scope advertised by the MCP protected-resource metadata endpoint.')
param entraAppScope string = 'user_impersonation'

@description('App role required in the caller token. Separate from MCP Frontend roles.')
param entraAppRole string = 'AIOMcpAdmin'

var usesSas = authMode == 'SharedAccessSignature'
var usesManagedIdentity = authMode == 'SystemAssignedManagedIdentity'
var hasMcp = endpointMode != 'a2a'
var mcpApiPath = 'mcp/${hybridConnectionName}${endpointMode == 'both' ? '-mcp' : ''}'
var supportsCustomCiphers = contains([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
], apimSku)
var listenerRole = '26e0b698-aa6d-4085-9386-aadae190014d'
var senderRole = '26baccc8-eea7-41f1-98f4-1762cc7f685d'
var endpointDefs = endpointMode == 'both' ? [
  {
    protocol: 'mcp'
    name: '${hybridConnectionName}-mcp'
  }
  {
    protocol: 'a2a'
    name: '${hybridConnectionName}-a2a'
  }
] : [
  {
    protocol: endpointMode
    name: hybridConnectionName
  }
]

resource cluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = if (usesManagedIdentity) {
  name: clusterName
}

resource extension 'Microsoft.KubernetesConfiguration/extensions@2022-11-01' existing = if (usesManagedIdentity) {
  name: aioExtensionName
  scope: cluster
}

resource relay 'Microsoft.Relay/namespaces@2021-11-01' = {
  name: relayNamespaceName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}

resource connections 'Microsoft.Relay/namespaces/hybridConnections@2021-11-01' = [for endpoint in endpointDefs: {
  parent: relay
  name: endpoint.name
  properties: {
    requiresClientAuthorization: true
  }
}]

resource listenRules 'Microsoft.Relay/namespaces/hybridConnections/authorizationRules@2021-11-01' = [for (endpoint, i) in endpointDefs: if (usesSas) {
  parent: connections[i]
  name: 'aio-ai-relay-listen'
  properties: {
    rights: [
      'Listen'
    ]
  }
}]

resource listeners 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (endpoint, i) in endpointDefs: if (usesManagedIdentity) {
  name: guid(connections[i].id, extension.id, listenerRole)
  scope: connections[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', listenerRole)
    principalId: extension!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource apim 'Microsoft.ApiManagement/service@2025-09-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: apimSku
    capacity: apimCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiVersionConstraint: {
      minApiVersion: '2019-12-01'
    }
    // V2 tiers don't support customizing the platform-managed cipher configuration.
    customProperties: supportsCustomCiphers ? {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA256': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA256': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_GCM_SHA256': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_GCM_SHA384': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA': 'False'
    } : null
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

// Native MCP combines this namespace URL with the Hybrid Connection endpoint path.
resource backends 'Microsoft.ApiManagement/service/backends@2025-09-01-preview' = [for endpoint in endpointDefs: {
  parent: apim
  name: 'aio-ai-relay-${endpoint.protocol}-backend'
  properties: {
    url: 'https://${relay.name}.servicebus.windows.net'
    protocol: 'http'
  }
}]

resource senders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (endpoint, i) in endpointDefs: {
  name: guid(connections[i].id, apim.id, senderRole)
  scope: connections[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', senderRole)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource apis 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = [for (endpoint, i) in endpointDefs: {
  parent: apim
  name: 'aio-ai-relay-${endpoint.protocol}'
  properties: union({
    displayName: 'aio-ai-relay ${toUpper(endpoint.protocol)} passthrough'
    path: endpoint.protocol == 'mcp' ? 'mcp' : '${endpoint.protocol}/${endpoint.name}'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }, endpoint.protocol == 'mcp' ? {
    type: 'mcp'
    backendId: backends[i].name
    mcpProperties: {
      endpoints: {
        mcp: {
          uriTemplate: '/${endpoint.name}'
        }
      }
    }
  } : {})
}]

var policyTemplate = '''
<policies>
  <inbound>
    <base />
    {0}
    <validate-azure-ad-token tenant-id="{1}" header-name="Authorization" output-token-variable-name="jwt">
      <audiences>
        <audience>api://{2}</audience>
        <audience>{2}</audience>
      </audiences>
      <required-claims>
        <claim name="roles" match="any"><value>{4}</value></claim>
      </required-claims>
    </validate-azure-ad-token>
    <authentication-managed-identity resource="https://relay.azure.net" output-token-variable-name="relay-access-token" ignore-error="false" />
    <set-header name="ServiceBusAuthorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["relay-access-token"])</value>
    </set-header>
    {3}
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
'''

var a2aRewrite = '''
    <choose>
      <when condition="@(context.Request.Method == &quot;GET&quot; &amp;&amp; context.Request.OriginalUrl.Path.EndsWith(&quot;/.well-known/agent-card.json&quot;))">
        <rewrite-uri template="/" />
      </when>
    </choose>
'''

resource policies 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = [for (endpoint, i) in endpointDefs: {
  parent: apis[i]
  name: 'policy'
  properties: {
    format: 'xml'
    value: format(
      policyTemplate,
      endpoint.protocol == 'a2a' ? a2aRewrite : '',
      entraTenantId,
      entraAppId,
      endpoint.protocol == 'mcp' ? '' : '<set-backend-service base-url="https://${relay.name}.servicebus.windows.net/${endpoint.name}" />',
      entraAppRole
    )
  }
  dependsOn: [
    backends[i]
    postOperations[i]
  ]
}]

resource getOperations 'Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview' = [for (endpoint, i) in endpointDefs: if (endpoint.protocol != 'mcp') {
  parent: apis[i]
  name: 'get-passthrough'
  properties: {
    displayName: 'GET passthrough'
    method: 'GET'
    urlTemplate: '/*'
  }
}]

resource postOperations 'Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview' = [for (endpoint, i) in endpointDefs: if (endpoint.protocol != 'mcp') {
  parent: apis[i]
  name: 'post-passthrough'
  properties: {
    displayName: 'POST passthrough'
    method: 'POST'
    urlTemplate: '/*'
  }
  dependsOn: [
    getOperations[i]
  ]
}]

resource oauthMetadataApi 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = if (hasMcp) {
  parent: apim
  name: 'oauth'
  properties: {
    displayName: 'oauth'
    description: 'OAuth protected-resource metadata for aio-ai-relay MCP'
    path: ''
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource oauthMetadataOperation 'Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview' = if (hasMcp) {
  parent: oauthMetadataApi
  name: 'get'
  properties: {
    displayName: 'Get MCP OAuth protected resource metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource/${mcpApiPath}'
    responses: []
  }
}

var oauthMetadataBody = string({
  resource: '${apim.properties.gatewayUrl}/${mcpApiPath}'
  authorization_servers: [
    '${environment().authentication.loginEndpoint}${entraTenantId}/v2.0'
  ]
  scopes_supported: [
    'api://${entraAppId}/${entraAppScope}'
  ]
  bearer_methods_supported: [
    'header'
  ]
})

var oauthMetadataPolicyTemplate = '''
<policies>
  <inbound>
    <base />
    <return-response>
      <set-status code="200" reason="OK" />
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>{0}</set-body>
    </return-response>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
'''

resource oauthMetadataPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = if (hasMcp) {
  parent: oauthMetadataApi
  name: 'policy'
  properties: {
    format: 'xml'
    value: format(oauthMetadataPolicyTemplate, replace(replace(replace(oauthMetadataBody, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'))
  }
  dependsOn: [
    oauthMetadataOperation
  ]
}

output endpoints array = [for (endpoint, i) in endpointDefs: {
  protocol: endpoint.protocol
  hybridConnectionName: endpoint.name
  apimApiPath: '${endpoint.protocol}/${endpoint.name}'
  apimGatewayUrl: '${apim.properties.gatewayUrl}/${endpoint.protocol}/${endpoint.name}'
  relayUrl: 'https://${relay.name}.servicebus.windows.net/${endpoint.name}'
  sasKeyName: usesSas ? listenRules[i].name : ''
}]

output authMode string = authMode
output mcpOAuthProtectedResourceMetadataUrl string = hasMcp ? '${apim.properties.gatewayUrl}/.well-known/oauth-protected-resource/${mcpApiPath}' : ''
output managedIdentityPrincipalId string = usesManagedIdentity ? extension!.identity.principalId : ''
